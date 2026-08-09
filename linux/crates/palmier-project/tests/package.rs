use std::fs;
use std::os::unix::fs::MetadataExt;

use palmier_project::{
    ClipType, MANIFEST_FILENAME, MEDIA_DIRECTORY_NAME, ManifestState, MediaManifest,
    MediaManifestEntry, MediaSource, PROJECT_FILENAME, ProjectError, ProjectFile,
    ProjectPackageStore, ProjectSnapshot,
};
use tempfile::TempDir;

fn project(id: &str) -> ProjectFile {
    let timeline = palmier_project::core::Timeline {
        id: id.to_owned(),
        ..palmier_project::core::Timeline::default()
    };
    ProjectFile::new(vec![timeline]).unwrap()
}

fn manifest() -> MediaManifest {
    let mut manifest = MediaManifest::default();
    manifest.entries.push(MediaManifestEntry {
        id: "asset-1".to_owned(),
        name: "Clip".to_owned(),
        media_type: ClipType::Video,
        source: MediaSource::Project {
            relative_path: "media/clip.mp4".to_owned(),
        },
        duration: 1.0,
        generation_input: None,
        source_width: None,
        source_height: None,
        source_fps: None,
        has_audio: None,
        folder_id: None,
        cached_remote_url: None,
        cached_remote_url_expires_at: None,
        generation_status: None,
        import_input: None,
    });
    manifest
}

#[tokio::test]
async fn open_save_roundtrip() {
    let temporary = TempDir::new().unwrap();
    let package = temporary.path().join("Roundtrip.palmier");
    let project = project("timeline-1");
    let snapshot = ProjectSnapshot::new(project.clone(), manifest());

    ProjectPackageStore::new()
        .save(&package, snapshot)
        .await
        .unwrap();
    let opened = ProjectPackageStore::new().open(&package).await.unwrap();

    assert_eq!(opened.project, project);
    assert!(matches!(opened.manifest, ManifestState::Valid(_)));
    assert!(package.join(MEDIA_DIRECTORY_NAME).is_dir());
}

#[tokio::test]
async fn corrupt_manifest_and_package_entries_survive_save_and_save_as() {
    let temporary = TempDir::new().unwrap();
    let source = temporary.path().join("Source.palmier");
    fs::create_dir_all(source.join("media")).unwrap();
    fs::create_dir_all(source.join("chat")).unwrap();
    fs::write(
        source.join(PROJECT_FILENAME),
        serde_json::to_vec(&project("timeline-1")).unwrap(),
    )
    .unwrap();
    let corrupt = b"{ not valid media json".to_vec();
    fs::write(source.join(MANIFEST_FILENAME), &corrupt).unwrap();
    fs::write(source.join("media/source.mp4"), b"media").unwrap();
    fs::write(source.join("thumbnail.jpg"), b"thumbnail").unwrap();
    fs::write(source.join("chat/session.json"), b"chat").unwrap();
    fs::write(source.join("future-entry.bin"), b"future").unwrap();

    let store = ProjectPackageStore::new();
    let opened = store.open(&source).await.unwrap();
    assert_eq!(opened.manifest, ManifestState::Corrupt(corrupt.clone()));
    let mut snapshot = opened.snapshot();
    snapshot.project.active_timeline_id = Some("timeline-1".to_owned());
    store.save(&source, snapshot.clone()).await.unwrap();

    assert_eq!(fs::read(source.join(MANIFEST_FILENAME)).unwrap(), corrupt);
    assert_eq!(fs::read(source.join("media/source.mp4")).unwrap(), b"media");
    assert_eq!(
        fs::read(source.join("thumbnail.jpg")).unwrap(),
        b"thumbnail"
    );
    assert_eq!(fs::read(source.join("chat/session.json")).unwrap(), b"chat");
    assert_eq!(
        fs::read(source.join("future-entry.bin")).unwrap(),
        b"future"
    );

    let destination = temporary.path().join("Copy.palmier");
    store
        .save_as(&source, &destination, snapshot)
        .await
        .unwrap();
    assert_eq!(
        fs::read(destination.join(MANIFEST_FILENAME)).unwrap(),
        corrupt
    );
    assert_eq!(
        fs::read(destination.join("future-entry.bin")).unwrap(),
        b"future"
    );
}

#[tokio::test]
async fn replacing_existing_package_exchanges_complete_directory() {
    let temporary = TempDir::new().unwrap();
    let package = temporary.path().join("Atomic.palmier");
    let store = ProjectPackageStore::new();
    store
        .save(
            &package,
            ProjectSnapshot::new(project("first"), MediaManifest::default()),
        )
        .await
        .unwrap();
    fs::write(package.join("unknown"), b"preserved").unwrap();
    let previous_inode = fs::metadata(&package).unwrap().ino();

    let report = store
        .save(
            &package,
            ProjectSnapshot::new(project("second"), MediaManifest::default()),
        )
        .await
        .unwrap();

    assert!(report.replaced_existing);
    assert_ne!(fs::metadata(&package).unwrap().ino(), previous_inode);
    assert_eq!(fs::read(package.join("unknown")).unwrap(), b"preserved");
    let saved =
        ProjectFile::decode_json(&fs::read(package.join(PROJECT_FILENAME)).unwrap()).unwrap();
    assert_eq!(saved.timelines[0].id, "second");
}

#[tokio::test]
async fn cancelled_save_does_not_replace_destination() {
    let temporary = TempDir::new().unwrap();
    let package = temporary.path().join("Cancelled.palmier");
    let store = ProjectPackageStore::new();
    store
        .save(
            &package,
            ProjectSnapshot::new(project("original"), MediaManifest::default()),
        )
        .await
        .unwrap();
    let cancellation = palmier_project::CancellationToken::new();
    cancellation.cancel();

    let result = store
        .save_with_cancellation(
            &package,
            ProjectSnapshot::new(project("replacement"), MediaManifest::default()),
            cancellation,
        )
        .await;

    assert!(matches!(result, Err(ProjectError::Cancelled)));
    let reopened = store.open(&package).await.unwrap();
    assert_eq!(reopened.project.timelines[0].id, "original");
}
