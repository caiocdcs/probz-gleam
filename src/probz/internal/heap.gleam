//// A persistent pairing min-heap ordered by `#(Int, Int)` keys.

pub opaque type Heap(a) {
  Empty
  Node(key: #(Int, Int), value: a, children: List(Heap(a)))
}

pub fn new() -> Heap(a) {
  Empty
}

fn less(a: #(Int, Int), b: #(Int, Int)) -> Bool {
  a.0 < b.0 || { a.0 == b.0 && a.1 < b.1 }
}

fn meld(a: Heap(a), b: Heap(a)) -> Heap(a) {
  case a, b {
    Empty, _ -> b
    _, Empty -> a
    Node(ka, va, ca), Node(kb, vb, cb) ->
      case less(kb, ka) {
        True -> Node(kb, vb, [a, ..cb])
        False -> Node(ka, va, [b, ..ca])
      }
  }
}

pub fn insert(heap: Heap(a), key: #(Int, Int), value: a) -> Heap(a) {
  meld(Node(key, value, []), heap)
}

pub fn find_min(heap: Heap(a)) -> Result(#(#(Int, Int), a), Nil) {
  case heap {
    Empty -> Error(Nil)
    Node(key, value, _) -> Ok(#(key, value))
  }
}

pub fn delete_min(heap: Heap(a)) -> Heap(a) {
  case heap {
    Empty -> Empty
    Node(_, _, children) -> merge_pairs(children)
  }
}

fn merge_pairs(heaps: List(Heap(a))) -> Heap(a) {
  case heaps {
    [] -> Empty
    [h] -> h
    [a, b, ..rest] -> meld(meld(a, b), merge_pairs(rest))
  }
}
