#![no_main]
//! libFuzzer harness for gjson.rs (additive — does not touch upstream).
//!
//! Drives gjson's public parse/query surface on arbitrary bytes, mirroring the
//! upstream afl harness (extra/fuzz/src/main.rs): treat the input as UTF-8, use it
//! both as JSON document and as a query path, and walk the resulting Value with the
//! accessor API (raw/str/json/typed getters/each/array). The harness only CALLS
//! upstream code — any panic/UB it surfaces is an upstream defect (a PoV), never to
//! be "fixed" here.
use libfuzzer_sys::fuzz_target;

const JSON: &str = r#"
{
  "name": {"first": "Tom", "last": "Anderson"},
  "age":37,
  "children": ["Sara","Alex","Jack"],
  "fav.movie": "Deer Hunter",
  "friends": [
    {"first": "Dale", "last": "Murphy", "age": 44, "nets": ["ig", "fb", "tw"]},
    {"first": "Roger", "last": "Craig", "age": 68, "nets": ["fb", "tw"]},
    {"first": "Jane", "last": "Murphy", "age": 47, "nets": ["ig", "tw"]}
  ]
}
"#;

// Walk a Value through every public accessor so the fuzzer reaches the conversion /
// formatting code paths, not just the parser.
fn exercise(v: &gjson::Value) {
    let _ = v.exists();
    let _ = v.kind();
    let _ = v.json();
    let _ = v.f64();
    let _ = v.f32();
    let _ = v.i64();
    let _ = v.u64();
    let _ = v.i32();
    let _ = v.i16();
    let _ = v.i8();
    let _ = v.u32();
    let _ = v.u16();
    let _ = v.u8();
    let _ = v.bool();
    let _ = v.str();
    let _ = v.json();
    // iterate object/array members (and run a nested query off each value)
    let mut n = 0u32;
    v.each(|_k, val| {
        let _ = val.json();
        n += 1;
        n < 256 // bound the walk
    });
    let _ = v.array();
}

fuzz_target!(|data: &[u8]| {
    let s = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => return,
    };

    // 1) input as both document and path (the upstream afl harness pattern)
    let r1 = gjson::get(s, s);
    exercise(&r1);

    // 2) input as a query path against a fixed, well-formed document
    let r2 = gjson::get(JSON, s);
    exercise(&r2);

    // 3) input as a document parsed directly, then chained sub-queries
    let p = gjson::parse(s);
    exercise(&p);
    let sub = p.get("name.first");
    exercise(&sub);
});
