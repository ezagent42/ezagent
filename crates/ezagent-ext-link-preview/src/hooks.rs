//! Link preview hooks for the Link Preview extension.
//!
//! This module provides URL extraction from message text. URLs are
//! identified by the `http://` or `https://` prefix and extend to
//! the next whitespace character.
//!
//! This is a basic, best-effort extraction — it is not a full URL
//! parser. The goal is to identify likely URLs for preview generation
//! during the `after_read` hook phase.

/// URL scheme prefixes that are recognized for extraction.
const URL_PREFIXES: &[&str] = &["https://", "http://"];

/// Extract URLs from text.
///
/// Scans the input text for substrings starting with `http://` or
/// `https://` and returns them as a `Vec<&str>`. Each URL extends
/// from the scheme prefix to the next whitespace character (or end
/// of string).
///
/// # Examples
///
/// ```
/// use ezagent_ext_link_preview::hooks::extract_urls;
///
/// let urls = extract_urls("Visit https://example.com for details");
/// assert_eq!(urls, vec!["https://example.com"]);
/// ```
pub fn extract_urls(text: &str) -> Vec<&str> {
    let mut urls = Vec::new();
    let mut search_start = 0;

    while search_start < text.len() {
        let remaining = &text[search_start..];

        // Find the earliest URL prefix in the remaining text.
        let mut earliest: Option<(usize, usize)> = None; // (abs_pos, prefix_len)
        for prefix in URL_PREFIXES {
            if let Some(pos) = remaining.find(prefix) {
                let abs_pos = search_start + pos;
                match earliest {
                    Some((ep, _)) if abs_pos < ep => {
                        earliest = Some((abs_pos, prefix.len()));
                    }
                    None => {
                        earliest = Some((abs_pos, prefix.len()));
                    }
                    _ => {}
                }
            }
        }

        match earliest {
            Some((start_pos, _)) => {
                // Find the end of the URL (next whitespace or end of string).
                let url_slice = &text[start_pos..];
                let end = url_slice
                    .find(char::is_whitespace)
                    .unwrap_or(url_slice.len());
                urls.push(&text[start_pos..start_pos + end]);
                search_start = start_pos + end;
            }
            None => break,
        }
    }

    urls
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_single_https() {
        let urls = extract_urls("Visit https://example.com today");
        assert_eq!(urls, vec!["https://example.com"]);
    }

    #[test]
    fn extract_single_http() {
        let urls = extract_urls("See http://example.org/page");
        assert_eq!(urls, vec!["http://example.org/page"]);
    }

    #[test]
    fn extract_multiple() {
        let urls = extract_urls("https://a.com and http://b.org here");
        assert_eq!(urls, vec!["https://a.com", "http://b.org"]);
    }

    #[test]
    fn extract_url_with_path_and_query() {
        let urls = extract_urls("Go to https://example.com/path?q=1&r=2#frag now");
        assert_eq!(urls, vec!["https://example.com/path?q=1&r=2#frag"]);
    }

    #[test]
    fn extract_url_at_start() {
        let urls = extract_urls("https://example.com is a site");
        assert_eq!(urls, vec!["https://example.com"]);
    }

    #[test]
    fn extract_url_at_end() {
        let urls = extract_urls("Visit https://example.com");
        assert_eq!(urls, vec!["https://example.com"]);
    }

    #[test]
    fn extract_no_urls() {
        let urls = extract_urls("Hello, world! No links here.");
        assert!(urls.is_empty());
    }

    #[test]
    fn extract_empty_string() {
        let urls = extract_urls("");
        assert!(urls.is_empty());
    }

    #[test]
    fn extract_ftp_not_matched() {
        let urls = extract_urls("ftp://files.example.com/data.zip");
        assert!(urls.is_empty());
    }

    #[test]
    fn extract_url_only() {
        let urls = extract_urls("https://example.com");
        assert_eq!(urls, vec!["https://example.com"]);
    }

    #[test]
    fn extract_adjacent_urls() {
        // URLs separated by a single space.
        let urls = extract_urls("https://a.com https://b.com");
        assert_eq!(urls, vec!["https://a.com", "https://b.com"]);
    }
}
