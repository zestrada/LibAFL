use crate::AflError;
use crate::executors::Executor;

pub trait Observer {

    fn flush(&mut self) -> Result<(), AflError> {
        Ok(())
    }

    fn reset(&mut self) -> Result<(), AflError>;

    fn post_exec(&mut self) -> Result<(), AflError> {
        Ok(())
    }

}
