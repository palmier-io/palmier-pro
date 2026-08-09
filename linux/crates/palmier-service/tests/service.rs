use std::fs;
use std::path::PathBuf;

use palmier_core::{ClipType, EditorCommand, MutationStatus};
use palmier_project::{
    MEDIA_DIRECTORY_NAME, MediaSource, ProjectPackageStore, RecentProjectRegistry,
};
use palmier_service::{EditorService, ImportMode, ServiceError};
use tempfile::TempDir;

async fn service_with_temp_registry() -> (TempDir, EditorService) {
    let temporary = TempDir::new().unwrap();
    let registry_path = temporary.path().join("registry.json");
    let registry = RecentProjectRegistry::open(&registry_path).await.unwrap();
    let service = EditorService::with_parts(ProjectPackageStore::new(), registry);
    (temporary, service)
}

#[tokio::test]
async fn commit_rejects_revision_mismatch() {
    let (_temporary, service) = service_with_temp_registry().await;
    let project = service.create_project().await.unwrap();
    let timeline_id = project
        .summary
        .active_timeline_id
        .clone()
        .expect("active timeline");

    let error = service
        .commit_edit(
            project.summary.project_id,
            99,
            EditorCommand::AddTrack {
                timeline_id,
                track_type: ClipType::Video,
                requested_index: 0,
            },
        )
        .await
        .unwrap_err();

    match error {
        ServiceError::RevisionMismatch {
            expected, actual, ..
        } => {
            assert_eq!(expected, 99);
            assert_eq!(actual, 0);
        }
        other => panic!("unexpected error: {other}"),
    }
}

#[tokio::test]
async fn undo_groups_as_single_history_entry() {
    let (_temporary, service) = service_with_temp_registry().await;
    let project = service.create_project().await.unwrap();
    let project_id = project.summary.project_id;
    let timeline_id = project.summary.active_timeline_id.clone().unwrap();

    let added = service
        .commit_edit(
            project_id,
            0,
            EditorCommand::AddTrack {
                timeline_id: timeline_id.clone(),
                track_type: ClipType::Video,
                requested_index: 0,
            },
        )
        .await
        .unwrap();
    assert_eq!(added.receipt.status, MutationStatus::Applied);
    assert_eq!(added.revision, 1);
    assert_eq!(
        added.snapshot.as_ref().unwrap().project.timelines[0]
            .tracks
            .len(),
        1
    );

    let undone = service.undo(project_id, 1).await.unwrap();
    assert_eq!(undone.receipt.status, MutationStatus::Undone);
    assert_eq!(undone.revision, 2);
    assert!(
        undone.snapshot.as_ref().unwrap().project.timelines[0]
            .tracks
            .is_empty()
    );

    let redone = service.redo(project_id, 2).await.unwrap();
    assert_eq!(redone.receipt.status, MutationStatus::Redone);
    assert_eq!(redone.revision, 3);
    assert_eq!(
        redone.snapshot.as_ref().unwrap().project.timelines[0]
            .tracks
            .len(),
        1
    );

    let preview = service
        .preview_edit(
            project_id,
            3,
            EditorCommand::AddTrack {
                timeline_id,
                track_type: ClipType::Audio,
                requested_index: 1,
            },
        )
        .await
        .unwrap();
    assert_eq!(preview.receipt.status, MutationStatus::Applied);
    assert_eq!(preview.snapshot.project.timelines[0].tracks.len(), 2);

    let current = service.project_view(project_id).await.unwrap();
    assert_eq!(current.summary.revision, 3);
    assert_eq!(current.snapshot.project.timelines[0].tracks.len(), 1);
}

#[tokio::test]
async fn open_save_roundtrip_preserves_edits() {
    let (temporary, service) = service_with_temp_registry().await;
    let created = service.create_project().await.unwrap();
    let project_id = created.summary.project_id;
    let timeline_id = created.summary.active_timeline_id.clone().unwrap();

    service
        .commit_edit(
            project_id,
            0,
            EditorCommand::AddTrack {
                timeline_id,
                track_type: ClipType::Video,
                requested_index: 0,
            },
        )
        .await
        .unwrap();

    let package = temporary.path().join("Roundtrip.palmier");
    let saved = service.save_project_as(project_id, &package).await.unwrap();
    assert!(!saved.dirty);
    assert_eq!(saved.path.as_deref(), Some(package.as_path()));

    service.close_project(project_id).await.unwrap();
    let reopened = service.open_project(&package).await.unwrap();
    assert_eq!(reopened.snapshot.project.timelines[0].tracks.len(), 1);
    assert!(!reopened.summary.dirty);
    assert_eq!(reopened.summary.revision, 0);

    let bootstrap = service.bootstrap().await.unwrap();
    assert_eq!(bootstrap.open_projects.len(), 1);
    assert!(!bootstrap.recent_projects.is_empty());
}

#[tokio::test]
async fn close_rejects_late_commits() {
    let (_temporary, service) = service_with_temp_registry().await;
    let project = service.create_project().await.unwrap();
    let project_id = project.summary.project_id;
    let timeline_id = project.summary.active_timeline_id.clone().unwrap();

    service.close_project(project_id).await.unwrap();

    let error = service
        .commit_edit(
            project_id,
            0,
            EditorCommand::AddTrack {
                timeline_id,
                track_type: ClipType::Video,
                requested_index: 0,
            },
        )
        .await
        .unwrap_err();
    assert!(matches!(error, ServiceError::ProjectNotFound(_)));
}

#[tokio::test]
async fn import_planning_registers_external_refs() {
    let (temporary, service) = service_with_temp_registry().await;
    let project = service.create_project().await.unwrap();
    let project_id = project.summary.project_id;

    let media_path = temporary.path().join("clip.mp4");
    fs::write(&media_path, b"fake-video").unwrap();
    let unsupported = temporary.path().join("notes.txt");
    fs::write(&unsupported, b"text").unwrap();

    let imported = service
        .import_local_files(
            project_id,
            vec![media_path.clone(), unsupported],
            ImportMode::ExternalRefs,
            None,
        )
        .await
        .unwrap();

    assert_eq!(imported.entries.len(), 1);
    assert_eq!(imported.entries[0].media_type, ClipType::Video);
    assert!(!imported.entries[0].installed);
    assert!(
        imported
            .rejected_unsupported_names
            .iter()
            .any(|name| name == "notes.txt")
    );
    assert!(imported.dirty);

    let view = service.project_view(project_id).await.unwrap();
    assert_eq!(view.snapshot.media_manifest.entries.len(), 1);
    match &view.snapshot.media_manifest.entries[0].source {
        MediaSource::External { absolute_path } => {
            assert_eq!(
                PathBuf::from(absolute_path),
                media_path.canonicalize().unwrap()
            );
        }
        other => panic!("expected external source, got {other:?}"),
    }
}

#[tokio::test]
async fn import_can_install_into_saved_package() {
    let (temporary, service) = service_with_temp_registry().await;
    let project = service.create_project().await.unwrap();
    let project_id = project.summary.project_id;
    let package = temporary.path().join("Media.palmier");
    service.save_project_as(project_id, &package).await.unwrap();

    let media_path = temporary.path().join("audio.wav");
    fs::write(&media_path, b"RIFF").unwrap();

    let imported = service
        .import_local_files(
            project_id,
            vec![media_path],
            ImportMode::InstallIntoPackage,
            None,
        )
        .await
        .unwrap();

    assert_eq!(imported.entries.len(), 1);
    assert!(imported.entries[0].installed);
    assert!(
        package
            .join(MEDIA_DIRECTORY_NAME)
            .join("audio.wav")
            .is_file()
    );

    let view = service.project_view(project_id).await.unwrap();
    match &view.snapshot.media_manifest.entries[0].source {
        MediaSource::Project { relative_path } => {
            assert_eq!(relative_path, "media/audio.wav");
        }
        other => panic!("expected project source, got {other:?}"),
    }
}

#[tokio::test]
async fn preview_does_not_mutate_session_revision() {
    let (_temporary, service) = service_with_temp_registry().await;
    let project = service.create_project().await.unwrap();
    let project_id = project.summary.project_id;
    let timeline_id = project.summary.active_timeline_id.clone().unwrap();

    let preview = service
        .preview_edit(
            project_id,
            0,
            EditorCommand::AddTrack {
                timeline_id,
                track_type: ClipType::Video,
                requested_index: 0,
            },
        )
        .await
        .unwrap();
    assert_eq!(preview.receipt.revision_after, 1);

    let view = service.project_view(project_id).await.unwrap();
    assert_eq!(view.summary.revision, 0);
    assert!(view.snapshot.project.timelines[0].tracks.is_empty());
}
