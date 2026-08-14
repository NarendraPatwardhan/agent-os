use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Clone, Copy)]
pub(crate) struct Profile {
    pub(crate) name: &'static str,
    pub(crate) samples: usize,
    pub(crate) branches: usize,
    pub(crate) memory_machines: usize,
    pub(crate) fs_bytes: &'static [usize],
}

#[derive(Serialize)]
pub(crate) struct ArtifactMeta {
    pub(crate) name: String,
    pub(crate) sha256: String,
    pub(crate) bytes: usize,
}

pub(crate) struct Artifact {
    pub(crate) meta: ArtifactMeta,
    pub(crate) bytes: Vec<u8>,
    pub(crate) path: PathBuf,
}

#[derive(Serialize)]
pub(crate) struct Stats {
    pub(crate) count: usize,
    pub(crate) p50: f64,
    pub(crate) p95: f64,
}

#[derive(Serialize)]
pub(crate) struct Failure {
    pub(crate) iteration: usize,
    pub(crate) error: String,
}

#[derive(Serialize)]
pub(crate) struct Measurement {
    pub(crate) name: String,
    pub(crate) unit: String,
    pub(crate) dimensions: BTreeMap<String, serde_json::Value>,
    pub(crate) samples: Vec<f64>,
    pub(crate) failures: Vec<Failure>,
    pub(crate) stats: Option<Stats>,
}

#[derive(Serialize)]
pub(crate) struct Check {
    pub(crate) name: String,
    pub(crate) ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) detail: Option<String>,
}

#[derive(Serialize)]
pub(crate) struct Skip {
    pub(crate) name: String,
    pub(crate) reason: String,
}

#[derive(Serialize)]
pub(crate) struct Run {
    pub(crate) id: String,
    pub(crate) timestamp: String,
    pub(crate) runner: String,
    pub(crate) runtime: String,
    pub(crate) profile: String,
    #[serde(rename = "sampleCount")]
    pub(crate) sample_count: usize,
    #[serde(rename = "branchCount")]
    pub(crate) branch_count: usize,
    pub(crate) system: serde_json::Value,
    pub(crate) artifacts: Vec<ArtifactMeta>,
    pub(crate) git: serde_json::Value,
    pub(crate) command: Vec<String>,
    pub(crate) semantics: serde_json::Value,
}

#[derive(Serialize)]
pub(crate) struct ResultDocument {
    pub(crate) schema: &'static str,
    pub(crate) run: Run,
    pub(crate) measurements: Vec<Measurement>,
    pub(crate) checks: Vec<Check>,
    pub(crate) skips: Vec<Skip>,
}

pub(crate) struct Results {
    pub(crate) doc: ResultDocument,
}

impl Results {
    pub(crate) fn new(run: Run) -> Self {
        Self {
            doc: ResultDocument {
                schema: "agentos.benchmark.v1",
                run,
                measurements: Vec::new(),
                checks: Vec::new(),
                skips: Vec::new(),
            },
        }
    }

    pub(crate) fn measurement_mut(
        &mut self,
        name: &str,
        unit: &str,
        dimensions: &BTreeMap<String, serde_json::Value>,
    ) -> &mut Measurement {
        if let Some(index) = self
            .doc
            .measurements
            .iter()
            .position(|m| m.name == name && m.unit == unit && m.dimensions == *dimensions)
        {
            return &mut self.doc.measurements[index];
        }
        self.doc.measurements.push(Measurement {
            name: name.to_owned(),
            unit: unit.to_owned(),
            dimensions: dimensions.clone(),
            samples: Vec::new(),
            failures: Vec::new(),
            stats: None,
        });
        self.doc.measurements.last_mut().unwrap()
    }

    pub(crate) fn sample(
        &mut self,
        name: &str,
        unit: &str,
        value: f64,
        dimensions: BTreeMap<String, serde_json::Value>,
    ) {
        assert!(
            value.is_finite() && value >= 0.0,
            "invalid sample for {name}"
        );
        let measurement = self.measurement_mut(name, unit, &dimensions);
        measurement.samples.push(value);
        measurement.stats = statistics(&measurement.samples);
    }

    pub(crate) fn failure(
        &mut self,
        name: &str,
        unit: &str,
        iteration: usize,
        error: impl std::fmt::Display,
        dimensions: BTreeMap<String, serde_json::Value>,
    ) {
        self.measurement_mut(name, unit, &dimensions)
            .failures
            .push(Failure {
                iteration,
                error: error.to_string(),
            });
    }

    pub(crate) fn check(&mut self, name: &str, ok: bool, detail: impl Into<Option<String>>) {
        self.doc.checks.push(Check {
            name: name.to_owned(),
            ok,
            detail: detail.into(),
        });
    }

    pub(crate) fn skip(&mut self, name: &str, reason: &str) {
        self.doc.skips.push(Skip {
            name: name.to_owned(),
            reason: reason.to_owned(),
        });
    }
}

pub(crate) fn statistics(values: &[f64]) -> Option<Stats> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let nearest = |q: f64| sorted[((q * sorted.len() as f64).ceil() as usize).max(1) - 1];
    Some(Stats {
        count: sorted.len(),
        p50: nearest(0.50),
        p95: nearest(0.95),
    })
}

pub(crate) fn dimensions(
    items: &[(&str, serde_json::Value)],
) -> BTreeMap<String, serde_json::Value> {
    items
        .iter()
        .map(|(key, value)| ((*key).to_owned(), value.clone()))
        .collect()
}

pub(crate) fn text(value: impl Into<String>) -> serde_json::Value {
    serde_json::Value::String(value.into())
}

pub(crate) fn number(value: usize) -> serde_json::Value {
    serde_json::Value::Number(value.into())
}

pub(crate) fn boolean(value: bool) -> serde_json::Value {
    serde_json::Value::Bool(value)
}

pub(crate) fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1_000.0
}
