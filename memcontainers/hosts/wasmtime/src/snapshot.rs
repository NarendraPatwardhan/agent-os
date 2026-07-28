use sha2::{Digest, Sha256};
use snapshot_rust::{SNAPSHOT_INTEGRITY_CHUNK_SIZE, SnapshotDigest};

const LEAF_DOMAIN: &[u8] = b"MCSN4-CHUNK\0";
const NODE_DOMAIN: &[u8] = b"MCSN4-NODE\0";
const ROOT_DOMAIN: &[u8] = b"MCSN4-ROOT\0";
const BASE_DOMAIN: &[u8] = b"MCSN4-BASE\0";

pub(crate) type ChunkHash = SnapshotDigest;

fn hash_node(level: usize, left: &ChunkHash, right: &ChunkHash) -> ChunkHash {
    let mut digest = Sha256::new();
    digest.update(NODE_DOMAIN);
    digest.update((level as u32).to_le_bytes());
    digest.update(left);
    digest.update(right);
    digest.finalize().into()
}

pub(crate) fn hash_chunk(index: usize, chunk: &[u8]) -> ChunkHash {
    let mut digest = Sha256::new();
    digest.update(LEAF_DOMAIN);
    digest.update((index as u32).to_le_bytes());
    digest.update((chunk.len() as u32).to_le_bytes());
    digest.update(chunk);
    digest.finalize().into()
}

pub(crate) fn chunk_hashes(memory: &[u8]) -> Vec<ChunkHash> {
    memory
        .chunks(SNAPSHOT_INTEGRITY_CHUNK_SIZE)
        .enumerate()
        .map(|(index, chunk)| hash_chunk(index, chunk))
        .collect()
}

/// Cached integrity tree over 1-MiB chunks. The root commits both the exact
/// memory length and the ordered chunk hashes; odd nodes pair with themselves.
#[derive(Clone)]
pub(crate) struct IntegrityTree {
    levels: Vec<Vec<ChunkHash>>,
    memory_len: usize,
}

impl IntegrityTree {
    pub(crate) fn from_memory(memory: &[u8]) -> Self {
        Self::new(chunk_hashes(memory), memory.len())
    }

    pub(crate) fn new(leaves: Vec<ChunkHash>, memory_len: usize) -> Self {
        assert!(!leaves.is_empty());
        let mut levels = vec![leaves];
        let mut level = 1usize;
        while levels.last().is_some_and(|nodes| nodes.len() > 1) {
            let prior = levels.last().expect("one level exists");
            let mut next = Vec::with_capacity(prior.len().div_ceil(2));
            for pair in prior.chunks(2) {
                let right = pair.get(1).unwrap_or(&pair[0]);
                next.push(hash_node(level, &pair[0], right));
            }
            levels.push(next);
            level += 1;
        }
        Self { levels, memory_len }
    }

    pub(crate) fn memory_len(&self) -> usize {
        self.memory_len
    }

    pub(crate) fn leaves(&self) -> &[ChunkHash] {
        &self.levels[0]
    }

    pub(crate) fn update(&mut self, chunk: usize, value: ChunkHash) {
        self.levels[0][chunk] = value;
        let mut child = chunk;
        for level in 1..self.levels.len() {
            let parent = child / 2;
            let lower = &self.levels[level - 1];
            let left = &lower[parent * 2];
            let right = lower.get(parent * 2 + 1).unwrap_or(left);
            self.levels[level][parent] = hash_node(level, left, right);
            child = parent;
        }
    }

    pub(crate) fn root(&self) -> SnapshotDigest {
        let top = self.levels.last().expect("one level")[0];
        let mut digest = Sha256::new();
        digest.update(ROOT_DOMAIN);
        digest.update((self.memory_len as u32).to_le_bytes());
        digest.update(top);
        digest.finalize().into()
    }
}

pub(crate) fn baseline_id(
    kernel_digest: &SnapshotDigest,
    memory_root: &SnapshotDigest,
    memory_len: usize,
) -> SnapshotDigest {
    let mut digest = Sha256::new();
    digest.update(BASE_DOMAIN);
    digest.update(kernel_digest);
    digest.update(memory_root);
    digest.update((memory_len as u32).to_le_bytes());
    digest.finalize().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn updating_one_chunk_matches_a_full_rebuild() {
        let mut memory = vec![0u8; SNAPSHOT_INTEGRITY_CHUNK_SIZE * 3];
        let mut tree = IntegrityTree::from_memory(&memory);
        memory[SNAPSHOT_INTEGRITY_CHUNK_SIZE + 17] = 0x5a;
        tree.update(
            1,
            hash_chunk(
                1,
                &memory[SNAPSHOT_INTEGRITY_CHUNK_SIZE..SNAPSHOT_INTEGRITY_CHUNK_SIZE * 2],
            ),
        );
        assert_eq!(tree.root(), IntegrityTree::from_memory(&memory).root());
    }
}
