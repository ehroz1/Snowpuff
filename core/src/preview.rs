//! What can be tried out before its day or its release: each turned on by SNOWPUFF_<NAME>=1 as the app starts, or built
//! into a test build that needs no setting up by naming it in SNOWPUFF_PREVIEWS as the app is compiled, as in
//! SNOWPUFF_PREVIEWS="new_year midnight fight".

pub fn on(name: &str) -> bool {
    std::env::var(format!("SNOWPUFF_{}", name.to_ascii_uppercase())).is_ok_and(|value| value == "1")
        || option_env!("SNOWPUFF_PREVIEWS").is_some_and(|built| built.split_whitespace().any(|built| built == name))
}
