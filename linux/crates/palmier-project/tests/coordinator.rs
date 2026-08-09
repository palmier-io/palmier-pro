use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use palmier_project::{CoordinatorError, PackageCoordinator};

#[tokio::test]
async fn queued_mutation_runs_after_final_successful_save() {
    let coordinator = PackageCoordinator::new();
    let first_save = coordinator.start_save();
    let second_save = coordinator.start_save();
    let ran = Arc::new(AtomicBool::new(false));

    let mutation = {
        let coordinator = coordinator.clone();
        let ran = ran.clone();
        tokio::spawn(async move {
            let mut permit = coordinator.admit_mutation().unwrap();
            permit.wait_until_ready().await.unwrap();
            ran.store(true, Ordering::SeqCst);
        })
    };
    while coordinator.queued_mutations() == 0 {
        tokio::task::yield_now().await;
    }
    assert!(!ran.load(Ordering::SeqCst));

    first_save.finish(false);
    tokio::task::yield_now().await;
    assert!(!ran.load(Ordering::SeqCst));
    second_save.finish(true);
    mutation.await.unwrap();
    assert!(ran.load(Ordering::SeqCst));
}

#[tokio::test]
async fn failed_final_save_rejects_queued_mutation() {
    let coordinator = PackageCoordinator::new();
    let save = coordinator.start_save();
    let mutation = {
        let coordinator = coordinator.clone();
        tokio::spawn(async move {
            let mut permit = coordinator.admit_mutation().unwrap();
            permit.wait_until_ready().await
        })
    };
    while coordinator.queued_mutations() == 0 {
        tokio::task::yield_now().await;
    }

    save.finish(false);

    assert_eq!(mutation.await.unwrap(), Err(CoordinatorError::SaveFailed));
}

#[tokio::test]
async fn close_waits_for_admitted_work_and_rejects_late_work() {
    let coordinator = PackageCoordinator::new();
    let mutation = coordinator.admit_mutation().unwrap();
    let (closing_sender, closing_receiver) = tokio::sync::oneshot::channel();
    let closing = {
        let coordinator = coordinator.clone();
        tokio::spawn(async move {
            let _ = closing_sender.send(());
            coordinator.begin_close().await;
        })
    };
    closing_receiver.await.unwrap();
    while !coordinator.is_closing() {
        tokio::task::yield_now().await;
    }

    assert!(coordinator.is_closing());
    assert!(matches!(
        coordinator.admit_mutation(),
        Err(CoordinatorError::Closing)
    ));
    assert!(!closing.is_finished());

    drop(mutation);
    closing.await.unwrap();
    assert!(coordinator.is_closing());
}

#[tokio::test]
async fn cancelling_queued_mutation_releases_close_waiters() {
    let coordinator = PackageCoordinator::new();
    let save = coordinator.start_save();
    let mutation = {
        let coordinator = coordinator.clone();
        tokio::spawn(async move {
            let mut permit = coordinator.admit_mutation().unwrap();
            permit.wait_until_ready().await
        })
    };
    while coordinator.queued_mutations() == 0 {
        tokio::task::yield_now().await;
    }

    mutation.abort();
    let _ = mutation.await;
    assert_eq!(coordinator.queued_mutations(), 0);
    assert_eq!(coordinator.active_mutations(), 0);
    save.finish(true);
    coordinator.wait_until_idle().await;
}
