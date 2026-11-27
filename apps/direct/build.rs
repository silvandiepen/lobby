// SPDX-License-Identifier: MPL-2.0
//! Compiles libjuice v1.7.5 (MPL-2.0, vendor/libjuice, unchanged) into the binary.
fn main() {
    let dir = "vendor/libjuice";
    let mut build = cc::Build::new();
    build
        .include(format!("{dir}/include"))
        .include(format!("{dir}/include/juice"))
        .define("JUICE_STATIC", None)
        .define("USE_NETTLE", "0")
        .flag_if_supported("-std=gnu11")
        .flag_if_supported("-fstack-protector-strong")
        .define("_FORTIFY_SOURCE", "2")
        .warnings(false);
    let mut sources: Vec<_> = std::fs::read_dir(format!("{dir}/src"))
        .expect("vendor/libjuice/src")
        .map(|entry| entry.expect("a file").path())
        .filter(|path| path.extension().is_some_and(|one| one == "c"))
        .collect();
    // The order on disk differs between machines, and the binary should not.
    sources.sort();
    for source in sources {
        build.file(source);
    }
    build.compile("juice");
    println!("cargo:rerun-if-changed={dir}");
}
