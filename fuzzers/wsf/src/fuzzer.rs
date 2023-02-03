use core::{ptr::addr_of_mut,time::Duration,ptr};
use std::{env, path::PathBuf, process};
use libc::{shmctl};

use libafl::{
    bolts::{
        core_affinity::Cores,
        current_nanos,
        launcher::Launcher,
        rands::StdRand,
        shmem::{ShMemProvider, StdShMemProvider},
        tuples::{tuple_list,Merge},
        AsSlice,
        AsMutSlice
    },
    corpus::{Corpus, InMemoryCorpus, OnDiskCorpus},
    events::EventConfig,
    //events::SimpleEventManager,
    executors::{ExitKind, TimeoutExecutor},
    feedback_or, feedback_or_fast,
    feedbacks::{CrashFeedback, MaxMapFeedback, TimeFeedback, TimeoutFeedback},
    fuzzer::{Fuzzer, StdFuzzer},
    inputs::{BytesInput, HasBytesVec},
    //monitors::SimpleMonitor,
    monitors::MultiMonitor,
    mutators::scheduled::{havoc_mutations, StdScheduledMutator, tokens_mutations},
    mutators::token_mutations::{Tokens},
    observers::{HitcountsMapObserver, TimeObserver, VariableMapObserver},
    schedulers::{IndexesLenTimeMinimizerScheduler, QueueScheduler},
    stages::StdMutationalStage,
    state::{HasCorpus, StdState, HasMetadata},
    Error,
};
use libafl_qemu::{
    emu::Emulator, QemuExecutor, QemuHooks, 
};
use libafl_targets::{edges_map_mut_slice, EDGES_MAP, MAX_EDGES_NUM};

pub const MAX_INPUT_SIZE: usize = 512;

//input symbols
#[no_mangle]
pub static mut __afl_input_ptr_local: [u8; MAX_INPUT_SIZE] = [0; MAX_INPUT_SIZE];
#[no_mangle]
pub static mut __afl_input_size: usize = 0;
pub use __afl_input_ptr_local as INPUT;
pub use __afl_input_size as INPUT_SIZE;

pub fn fuzz() {
    if let Ok(s) = env::var("FUZZ_SIZE") {
        str::parse::<usize>(&s).expect("FUZZ_SIZE was not a number");
    };
    // Hardcoded parameters
    let cores = Cores::from_cmdline("1").unwrap();
    let timeout = Duration::from_secs(10);
    let broker_port = 1337;
    let corpus_dirs = [PathBuf::from("./corpus")];
    let objective_dir = PathBuf::from("./crashes");
    let tokens_file =  PathBuf::from("./tokens/test.dict");
    let start_snap_name = env::var("SNAP_NAME").expect("SNAP_NAME not set");

    let mut run_client = |state: Option<_>, mut mgr, _core_id| {
        // Initialize QEMU
        let args: Vec<String> = env::args().collect();
        let env: Vec<(String, String)> = env::vars().collect();
        let emu = Emulator::new(&args, &env);

        // Load the specified snapshot from the qcow
        emu.load_snapshot(&start_snap_name, true);

        // Take a fast snapshot - Nah we'll use slow snaps
        //let snap = emu.create_fast_snapshot(true);

        // The harness closure
        let mut harness = |input: &BytesInput| {
            let mut buf = input.bytes().as_slice();
            let len = buf.len();

            //Now write some data, gotta convert to u8 slice
            unsafe {
                if len > MAX_INPUT_SIZE {
                    buf = &buf[0..MAX_INPUT_SIZE];
                    // len = MAX_INPUT_SIZE;
                }
                /*
                for (dst, src) in shm_input.iter_mut().zip(&buf) {
                        *dst = *src
                }
                */
                INPUT[..len].copy_from_slice(&buf[..len]);//src=buf, dst=input
                INPUT_SIZE = len;

                //println!("Before emu.run");
                emu.run();

                //println!("Before restore_fast_snap");
                //emu.restore_fast_snapshot(snap);
                //println!("After restore_fast_snap");
            }
            let ret = ExitKind::Ok;

            // Revert, either to our qcow or our fast snapshot
            emu.load_snapshot(&start_snap_name, true);
            //emu.restore_fast_snapshot(snap);

            ret
        };

        // Create an observation channel using the coverage map
        let edges_observer = unsafe {
            HitcountsMapObserver::new(VariableMapObserver::from_mut_slice(
                "edges",
                edges_map_mut_slice(),
                addr_of_mut!(MAX_EDGES_NUM),
            ))
        };

        // Create an observation channel to keep track of the execution time
        let time_observer = TimeObserver::new("time");

        // Feedback to rate the interestingness of an input
        // This one is composed by two Feedbacks in OR
        let mut feedback = feedback_or!(
            // New maximization map feedback linked to the edges observer and the feedback state
            MaxMapFeedback::new_tracking(&edges_observer, true, true),
            // Time feedback, this one does not need a feedback state
            TimeFeedback::with_observer(&time_observer)
        );

        // A feedback to choose if an input is a solution or not
        let mut objective = feedback_or_fast!(CrashFeedback::new(), TimeoutFeedback::new());

        // If not restarting, create a State from scratch
        let mut state = state.unwrap_or_else(|| {
            StdState::new(
                // RNG
                StdRand::with_seed(current_nanos()),
                // Corpus that will be evolved, we keep it in memory for performance
                InMemoryCorpus::new(),
                // Corpus in which we store solutions (crashes in this example),
                // on disk so the user can get them after stopping the fuzzer
                OnDiskCorpus::new(objective_dir.clone()).unwrap(),
                // States of the feedbacks.
                // The feedbacks can report the data that should persist in the State.
                &mut feedback,
                // Same for objective feedbacks
                &mut objective,
            )
            .unwrap()
        });

        // A minimization+queue policy to get testcasess from the corpus
        let scheduler = IndexesLenTimeMinimizerScheduler::new(QueueScheduler::new());

        // A fuzzer with feedbacks and a corpus scheduler
        let mut fuzzer = StdFuzzer::new(scheduler, feedback, objective);

        let mut hooks = QemuHooks::new(&emu, tuple_list!());

        // Create a QEMU in-process executor
        let executor = QemuExecutor::new(
            &mut hooks,
            &mut harness,
            tuple_list!(edges_observer, time_observer),
            &mut fuzzer,
            &mut state,
            &mut mgr,
        )
        .expect("Failed to create QemuExecutor");

        // Wrap the executor to keep track of the timeout
        let mut executor = TimeoutExecutor::new(executor, timeout);

        if state.corpus().count() < 1 {
            state
                .load_initial_inputs(&mut fuzzer, &mut executor, &mut mgr, &corpus_dirs)
                .unwrap_or_else(|_| {
                    println!("Failed to load initial corpus at {:?}", &corpus_dirs);
                    process::exit(0);
                });
            println!("We imported {} inputs from disk.", state.corpus().count());
        }

        // Setup an havoc mutator with a mutational stage
        let mutator = StdScheduledMutator::new(havoc_mutations().merge(tokens_mutations()));
        let mut stages = tuple_list!(StdMutationalStage::new(mutator));

        if state.metadata().get::<Tokens>().is_none() {
            state.add_metadata(Tokens::from_file(tokens_file.clone()).unwrap());
        }
        
        fuzzer
            .fuzz_loop(&mut stages, &mut executor, &mut state, &mut mgr)
            .unwrap();
        Ok(())
    };


    //let monitor = SimpleMonitor::new(|s| println!("{s}"));
    //let mgr = SimpleEventManager::new(monitor);
    //run_client(None, mgr, 0);

    // The stats reporter for the broker
    let monitor = MultiMonitor::new(|s| println!("{s}"));
    // The shared memory allocator
    let shmem_provider = StdShMemProvider::new().expect("Failed to init shared memory");


    // Build and run a Launcher
    match Launcher::builder()
        .shmem_provider(shmem_provider)
        .broker_port(broker_port)
        .configuration(EventConfig::from_build_id())
        .monitor(monitor)
        .run_client(&mut run_client)
        .cores(&cores)
        .stdout_file(Some("/tmp/fuzzer.txt"))
        .build()
        .launch()
    {
        Ok(()) => (),
        Err(Error::ShuttingDown) => println!("Fuzzing stopped by user. Good bye."),
        Err(err) => panic!("Failed to run launcher: {:?}", err),
    }
}
