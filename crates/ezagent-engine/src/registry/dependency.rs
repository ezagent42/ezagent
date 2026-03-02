//! Dependency resolution via Kahn's topological sort (bus-spec §3.1).
//!
//! Given a set of datatype IDs and their declared dependencies, this module
//! computes a deterministic load order that respects all dependency edges.
//! Ties between nodes with equal in-degree are broken alphabetically by ID
//! to ensure reproducible ordering.

use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};

use crate::error::EngineError;

/// Compute a topological load order for the given datatype IDs.
///
/// Uses Kahn's algorithm with alphabetical tie-breaking for determinism.
/// Returns `EngineError::CircularDependency` if a cycle exists, with the
/// `cycle` field describing the path (e.g. `"a → b → a"`).
///
/// # Arguments
///
/// * `ids` — All datatype IDs to include in the ordering.
/// * `deps` — Map from datatype ID to the list of IDs it depends on.
///   Every ID mentioned in a dependency list must also appear in `ids`.
pub fn resolve_load_order(
    ids: &[String],
    deps: &HashMap<String, Vec<String>>,
) -> Result<Vec<String>, EngineError> {
    // Build adjacency list (dependency → dependant) and in-degree map.
    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut in_degree: HashMap<&str, usize> = HashMap::new();

    for id in ids {
        in_degree.entry(id.as_str()).or_insert(0);
        adj.entry(id.as_str()).or_default();
    }

    for id in ids {
        if let Some(id_deps) = deps.get(id) {
            for dep in id_deps {
                adj.entry(dep.as_str()).or_default().push(id.as_str());
                *in_degree.entry(id.as_str()).or_insert(0) += 1;
            }
        }
    }

    // Seed the queue with zero in-degree nodes, sorted alphabetically.
    let mut queue: VecDeque<&str> = {
        let mut zeros: BTreeSet<&str> = BTreeSet::new();
        for (&id, &deg) in &in_degree {
            if deg == 0 {
                zeros.insert(id);
            }
        }
        zeros.into_iter().collect()
    };

    let mut result: Vec<String> = Vec::with_capacity(ids.len());

    while let Some(node) = queue.pop_front() {
        result.push(node.to_string());

        // Collect and sort neighbors for deterministic processing.
        let mut neighbors: Vec<&str> = adj.get(node).map_or(Vec::new(), |v| v.clone());
        neighbors.sort();

        for neighbor in neighbors {
            let deg = in_degree.get_mut(neighbor).expect("in_degree entry must exist");
            *deg -= 1;
            if *deg == 0 {
                // Insert into queue maintaining sorted order.
                let pos = queue
                    .iter()
                    .position(|&x| x > neighbor)
                    .unwrap_or(queue.len());
                queue.insert(pos, neighbor);
            }
        }
    }

    if result.len() != ids.len() {
        // Cycle detected — find and report it.
        let remaining: HashSet<&str> = ids
            .iter()
            .map(|s| s.as_str())
            .filter(|s| !result.contains(&s.to_string()))
            .collect();
        let cycle = find_cycle(&remaining, deps);
        return Err(EngineError::CircularDependency { cycle });
    }

    Ok(result)
}

/// Find a cycle among the remaining (unvisited) nodes using DFS.
///
/// Returns a human-readable cycle string like `"a → b → a"`.
fn find_cycle(remaining: &HashSet<&str>, deps: &HashMap<String, Vec<String>>) -> String {
    // Use iterative DFS with explicit path tracking.
    let mut visited: HashSet<&str> = HashSet::new();

    // Try each remaining node as a start point.
    // Sort for deterministic cycle reporting.
    let mut starts: Vec<&&str> = remaining.iter().collect();
    starts.sort();

    for &&start in &starts {
        if visited.contains(start) {
            continue;
        }

        // DFS stack: (node, index into its deps list)
        let mut path: Vec<&str> = vec![start];
        let mut path_set: HashSet<&str> = HashSet::new();
        path_set.insert(start);

        // Use a stack of iterators approach.
        let mut stack: Vec<(&str, usize)> = vec![(start, 0)];

        while let Some((node, idx)) = stack.last_mut() {
            let node_deps = deps.get(*node);
            let dep_list: Vec<&str> = node_deps
                .map(|d| d.iter().map(|s| s.as_str()).collect())
                .unwrap_or_default();

            if *idx >= dep_list.len() {
                // Backtrack.
                let removed = path.pop().unwrap_or_default();
                path_set.remove(removed);
                visited.insert(removed);
                stack.pop();
                continue;
            }

            let next = dep_list[*idx];
            *idx += 1;

            if !remaining.contains(next) {
                continue;
            }

            if path_set.contains(next) {
                // Found a cycle! Build the cycle string from where `next` first appears.
                let cycle_start = path.iter().position(|&n| n == next).unwrap_or(0);
                let mut cycle_path: Vec<&str> = path[cycle_start..].to_vec();
                cycle_path.push(next);
                return cycle_path.join(" \u{2192} ");
            }

            if !visited.contains(next) {
                path.push(next);
                path_set.insert(next);
                stack.push((next, 0));
            }
        }
    }

    // Fallback: should not happen if there is indeed a cycle.
    "unknown cycle".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_deps_returns_alphabetical() {
        let ids = vec!["c".into(), "a".into(), "b".into()];
        let deps = HashMap::new();
        let order = resolve_load_order(&ids, &deps).unwrap();
        assert_eq!(order, vec!["a", "b", "c"]);
    }

    #[test]
    fn linear_chain() {
        let ids = vec!["a".into(), "b".into(), "c".into()];
        let mut deps = HashMap::new();
        deps.insert("b".to_string(), vec!["a".to_string()]);
        deps.insert("c".to_string(), vec!["b".to_string()]);
        let order = resolve_load_order(&ids, &deps).unwrap();
        assert_eq!(order, vec!["a", "b", "c"]);
    }

    #[test]
    fn diamond_dependency() {
        // a → b, a → c, b → d, c → d
        let ids = vec!["a".into(), "b".into(), "c".into(), "d".into()];
        let mut deps = HashMap::new();
        deps.insert("b".to_string(), vec!["a".to_string()]);
        deps.insert("c".to_string(), vec!["a".to_string()]);
        deps.insert("d".to_string(), vec!["b".to_string(), "c".to_string()]);
        let order = resolve_load_order(&ids, &deps).unwrap();
        assert_eq!(order, vec!["a", "b", "c", "d"]);
    }

    #[test]
    fn cycle_detected() {
        let ids = vec!["a".into(), "b".into()];
        let mut deps = HashMap::new();
        deps.insert("a".to_string(), vec!["b".to_string()]);
        deps.insert("b".to_string(), vec!["a".to_string()]);
        let err = resolve_load_order(&ids, &deps).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("circular dependency"),
            "expected circular dependency error, got: {msg}"
        );
        // The cycle path should mention both a and b.
        assert!(msg.contains('a'), "cycle should mention 'a': {msg}");
        assert!(msg.contains('b'), "cycle should mention 'b': {msg}");
    }

    #[test]
    fn three_node_cycle() {
        let ids = vec!["a".into(), "b".into(), "c".into()];
        let mut deps = HashMap::new();
        deps.insert("a".to_string(), vec!["c".to_string()]);
        deps.insert("b".to_string(), vec!["a".to_string()]);
        deps.insert("c".to_string(), vec!["b".to_string()]);
        let err = resolve_load_order(&ids, &deps).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("circular dependency"), "got: {msg}");
    }

    #[test]
    fn builtin_order() {
        // identity < room < timeline < message
        let ids = vec![
            "identity".into(),
            "room".into(),
            "timeline".into(),
            "message".into(),
        ];
        let mut deps = HashMap::new();
        deps.insert("room".to_string(), vec!["identity".to_string()]);
        deps.insert(
            "timeline".to_string(),
            vec!["identity".to_string(), "room".to_string()],
        );
        deps.insert(
            "message".to_string(),
            vec![
                "identity".to_string(),
                "room".to_string(),
                "timeline".to_string(),
            ],
        );
        let order = resolve_load_order(&ids, &deps).unwrap();
        assert_eq!(order, vec!["identity", "room", "timeline", "message"]);
    }

    #[test]
    fn single_node_no_deps() {
        let ids = vec!["x".into()];
        let deps = HashMap::new();
        let order = resolve_load_order(&ids, &deps).unwrap();
        assert_eq!(order, vec!["x"]);
    }

    #[test]
    fn empty_input() {
        let ids: Vec<String> = vec![];
        let deps = HashMap::new();
        let order = resolve_load_order(&ids, &deps).unwrap();
        assert!(order.is_empty());
    }
}
