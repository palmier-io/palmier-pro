use std::collections::VecDeque;
use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard};

use thiserror::Error;
use tokio::sync::oneshot;

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum CoordinatorError {
    #[error("project is closing")]
    Closing,

    #[error("the save that guarded this mutation failed")]
    SaveFailed,
}

#[derive(Clone, Default)]
pub struct PackageCoordinator {
    inner: Arc<CoordinatorInner>,
}

#[derive(Default)]
struct CoordinatorInner {
    state: Mutex<CoordinatorState>,
}

#[derive(Default)]
struct CoordinatorState {
    saves_in_progress: usize,
    active_mutations: usize,
    next_waiter_id: u64,
    pending_mutations: VecDeque<PendingMutation>,
    idle_waiters: Vec<IdleWaiter>,
    closing: bool,
}

struct PendingMutation {
    id: u64,
    sender: oneshot::Sender<std::result::Result<(), CoordinatorError>>,
}

struct IdleWaiter {
    id: u64,
    sender: oneshot::Sender<()>,
}

impl PackageCoordinator {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn start_save(&self) -> SavePermit {
        let mut state = self.inner.lock();
        state.saves_in_progress += 1;
        SavePermit {
            inner: Some(self.inner.clone()),
        }
    }

    pub fn save_started(&self) -> SavePermit {
        self.start_save()
    }

    pub fn admit_mutation(&self) -> std::result::Result<MutationPermit, CoordinatorError> {
        let mut state = self.inner.lock();
        if state.closing {
            return Err(CoordinatorError::Closing);
        }
        state.active_mutations += 1;
        Ok(MutationPermit {
            inner: Some(self.inner.clone()),
            passed_save_gate: false,
        })
    }

    pub fn begin_mutation(&self) -> std::result::Result<MutationPermit, CoordinatorError> {
        self.admit_mutation()
    }

    pub async fn perform_mutation<T, E, F, Fut>(&self, operation: F) -> std::result::Result<T, E>
    where
        E: From<CoordinatorError>,
        F: FnOnce() -> Fut,
        Fut: Future<Output = std::result::Result<T, E>>,
    {
        let mut permit = self.admit_mutation().map_err(E::from)?;
        permit.wait_until_ready().await.map_err(E::from)?;
        operation().await
    }

    pub async fn begin_close(&self) {
        {
            let mut state = self.inner.lock();
            state.closing = true;
        }
        self.wait_until_idle().await;
    }

    pub async fn begin_closing(&self) {
        self.begin_close().await;
    }

    pub fn cancel_close(&self) {
        self.inner.lock().closing = false;
    }

    pub fn cancel_closing(&self) {
        self.cancel_close();
    }

    pub fn is_closing(&self) -> bool {
        self.inner.lock().closing
    }

    pub fn saves_in_progress(&self) -> usize {
        self.inner.lock().saves_in_progress
    }

    pub fn active_mutations(&self) -> usize {
        self.inner.lock().active_mutations
    }

    pub fn queued_mutations(&self) -> usize {
        self.inner.lock().pending_mutations.len()
    }

    pub async fn wait_until_idle(&self) {
        let (id, receiver) = {
            let mut state = self.inner.lock();
            if state.saves_in_progress == 0 && state.active_mutations == 0 {
                return;
            }
            let id = state.next_id();
            let (sender, receiver) = oneshot::channel();
            state.idle_waiters.push(IdleWaiter { id, sender });
            (id, receiver)
        };

        let mut registration = IdleRegistration {
            inner: Some(self.inner.clone()),
            id,
        };
        let _ = receiver.await;
        registration.disarm();
    }
}

impl CoordinatorInner {
    fn lock(&self) -> MutexGuard<'_, CoordinatorState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn finish_save(&self, success: bool) {
        let (pending, idle) = {
            let mut state = self.lock();
            if state.saves_in_progress == 0 {
                return;
            }
            state.saves_in_progress -= 1;
            if state.saves_in_progress != 0 {
                return;
            }
            let pending = state.pending_mutations.drain(..).collect::<Vec<_>>();
            let idle = state.take_idle_waiters_if_idle();
            (pending, idle)
        };

        let result = if success {
            Ok(())
        } else {
            Err(CoordinatorError::SaveFailed)
        };
        for pending in pending {
            let _ = pending.sender.send(result.clone());
        }
        for waiter in idle {
            let _ = waiter.sender.send(());
        }
    }

    fn finish_mutation(&self) {
        let idle = {
            let mut state = self.lock();
            if state.active_mutations == 0 {
                return;
            }
            state.active_mutations -= 1;
            state.take_idle_waiters_if_idle()
        };
        for waiter in idle {
            let _ = waiter.sender.send(());
        }
    }

    fn remove_pending_mutation(&self, id: u64) {
        let mut state = self.lock();
        if let Some(index) = state
            .pending_mutations
            .iter()
            .position(|pending| pending.id == id)
        {
            state.pending_mutations.remove(index);
        }
    }

    fn remove_idle_waiter(&self, id: u64) {
        self.lock().idle_waiters.retain(|waiter| waiter.id != id);
    }
}

impl CoordinatorState {
    fn next_id(&mut self) -> u64 {
        let id = self.next_waiter_id;
        self.next_waiter_id = self.next_waiter_id.wrapping_add(1);
        id
    }

    fn take_idle_waiters_if_idle(&mut self) -> Vec<IdleWaiter> {
        if self.saves_in_progress == 0 && self.active_mutations == 0 {
            std::mem::take(&mut self.idle_waiters)
        } else {
            Vec::new()
        }
    }
}

pub struct SavePermit {
    inner: Option<Arc<CoordinatorInner>>,
}

impl SavePermit {
    pub fn finish(mut self, success: bool) {
        if let Some(inner) = self.inner.take() {
            inner.finish_save(success);
        }
    }
}

impl Drop for SavePermit {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.take() {
            inner.finish_save(false);
        }
    }
}

pub struct MutationPermit {
    inner: Option<Arc<CoordinatorInner>>,
    passed_save_gate: bool,
}

impl MutationPermit {
    pub async fn wait_until_ready(&mut self) -> std::result::Result<(), CoordinatorError> {
        if self.passed_save_gate {
            return Ok(());
        }
        let inner = self.inner.as_ref().expect("live mutation permit").clone();
        let queued = {
            let mut state = inner.lock();
            if state.saves_in_progress == 0 {
                None
            } else {
                let id = state.next_id();
                let (sender, receiver) = oneshot::channel();
                state
                    .pending_mutations
                    .push_back(PendingMutation { id, sender });
                Some((id, receiver))
            }
        };

        if let Some((id, receiver)) = queued {
            let mut registration = MutationRegistration {
                inner: Some(inner),
                id,
            };
            let result = receiver.await.unwrap_or(Err(CoordinatorError::SaveFailed));
            registration.disarm();
            result?;
        }

        self.passed_save_gate = true;
        Ok(())
    }
}

impl Drop for MutationPermit {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.take() {
            inner.finish_mutation();
        }
    }
}

struct MutationRegistration {
    inner: Option<Arc<CoordinatorInner>>,
    id: u64,
}

impl MutationRegistration {
    fn disarm(&mut self) {
        self.inner = None;
    }
}

impl Drop for MutationRegistration {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.take() {
            inner.remove_pending_mutation(self.id);
        }
    }
}

struct IdleRegistration {
    inner: Option<Arc<CoordinatorInner>>,
    id: u64,
}

impl IdleRegistration {
    fn disarm(&mut self) {
        self.inner = None;
    }
}

impl Drop for IdleRegistration {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.take() {
            inner.remove_idle_waiter(self.id);
        }
    }
}
