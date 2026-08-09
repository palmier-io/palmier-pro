use std::collections::HashSet;
use std::fs;

use palmier_project::{
    InstallNamePolicy, MediaManifest, ProjectFile, ProjectPackageStore, ProjectSnapshot,
};
use tempfile::TempDir;

fn project() -> ProjectFile {
    ProjectFile::new(vec![palmier_project::core::Timeline::default()]).unwrap()
}

#[tokio::test]
async fn concurrent_media_installs_are_serialized_and_uniquely_named() {
    let temporary = TempDir::new().unwrap();
    let package = temporary.path().join("Concurrent.palmier");
    let store = ProjectPackageStore::new();
    store
        .save(
            &package,
            ProjectSnapshot::new(project(), MediaManifest::default()),
        )
        .await
        .unwrap();
    let first_stage = temporary.path().join("first.stage");
    let second_stage = temporary.path().join("second.stage");
    fs::write(&first_stage, b"first").unwrap();
    fs::write(&second_stage, b"second").unwrap();

    let installer = store.media_installer();
    let first = installer.install_staged_media(
        &package,
        &first_stage,
        "../clip.mp4",
        InstallNamePolicy::Unique,
        None,
    );
    let second = installer.install_staged_media(
        &package,
        &second_stage,
        "../clip.mp4",
        InstallNamePolicy::Unique,
        None,
    );
    let (first, second) = tokio::join!(first, second);
    let first = first.unwrap();
    let second = second.unwrap();

    assert_ne!(first.filename, second.filename);
    assert_eq!(
        HashSet::from([first.filename.clone(), second.filename.clone()]),
        HashSet::from(["clip.mp4".to_owned(), "clip-1.mp4".to_owned()])
    );
    let contents = HashSet::from([
        fs::read(first.path).unwrap(),
        fs::read(second.path).unwrap(),
    ]);
    assert_eq!(
        contents,
        HashSet::from([b"first".to_vec(), b"second".to_vec()])
    );
    assert!(!first_stage.exists());
    assert!(!second_stage.exists());
}
