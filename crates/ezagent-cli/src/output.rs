//! Output formatting: table / json / quiet modes.

/// Output format selector.
pub enum OutputFormat {
    /// Human-readable table layout.
    Table,
    /// Machine-readable JSON output.
    Json,
    /// Minimal output (IDs only, one per line).
    Quiet,
}

impl OutputFormat {
    /// Determine format from CLI flags.
    ///
    /// `--json` takes precedence over `--quiet`; if neither is set,
    /// defaults to [`OutputFormat::Table`].
    pub fn from_flags(json: bool, quiet: bool) -> Self {
        if json {
            Self::Json
        } else if quiet {
            Self::Quiet
        } else {
            Self::Table
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_flags_json_takes_precedence() {
        match OutputFormat::from_flags(true, true) {
            OutputFormat::Json => {}
            _ => panic!("json flag should take precedence"),
        }
    }

    #[test]
    fn from_flags_quiet() {
        match OutputFormat::from_flags(false, true) {
            OutputFormat::Quiet => {}
            _ => panic!("should be quiet"),
        }
    }

    #[test]
    fn from_flags_default_is_table() {
        match OutputFormat::from_flags(false, false) {
            OutputFormat::Table => {}
            _ => panic!("default should be table"),
        }
    }
}
