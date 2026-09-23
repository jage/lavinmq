/-!
# AMQP 0-9-1 topic exchange matching (§3.1.3.3)

A routing key is a list of words delimited by dots. In a binding key `*`
matches exactly one word and `#` matches zero or more words.

Models `TopicBindingKey` (the segment chain in `src/lavinmq/amqp/exchange/topic.cr`)
and `RkIterator`, which splits the routing key.

Proven here:
* the segment chain agrees with the specification for every binding key and
  every non-empty word list
* `RkIterator` drops a trailing empty word (`"a."` is read as `["a"]`), and the
  fixed iterator splits exactly like the specification
-/

namespace AmqpTopic

inductive Pat (α : Type) where
  | hash
  | star
  | word (w : α)
  deriving DecidableEq

variable {α : Type}

/-- `f` holds for some suffix of `ws`, the empty suffix included. -/
def anySuffix (f : List α → Bool) : List α → Bool
  | [] => f []
  | w :: ws => f (w :: ws) || anySuffix f ws

theorem anySuffix_iff (f : List α → Bool) (ws : List α) :
    anySuffix f ws = true ↔ ∃ pre post, ws = pre ++ post ∧ f post = true := by
  induction ws with
  | nil =>
    constructor
    · intro h; exact ⟨[], [], rfl, h⟩
    · rintro ⟨pre, post, heq, h⟩
      obtain ⟨rfl, rfl⟩ := List.append_eq_nil_iff.mp heq.symm
      exact h
  | cons w ws ih =>
    simp only [anySuffix, Bool.or_eq_true, ih]
    constructor
    · rintro (h | ⟨pre, post, rfl, h⟩)
      · exact ⟨[], _, rfl, h⟩
      · exact ⟨w :: pre, post, rfl, h⟩
    · rintro ⟨_ | ⟨p, pre⟩, post, heq, h⟩
      · left; simp at heq; rw [heq]; exact h
      · right; simp at heq; exact ⟨pre, post, heq.2, h⟩

theorem anySuffix_of_nil (f : List α → Bool) (h : f [] = true) (ws : List α) :
    anySuffix f ws = true := by
  induction ws with
  | nil => exact h
  | cons w ws ih => simp [anySuffix, ih]

/-- The specification: `#` consumes any prefix, `*` one word, a word itself. -/
def spec [DecidableEq α] : List (Pat α) → List α → Bool
  | [], ws => ws.isEmpty
  | .hash :: ps, ws => anySuffix (spec ps) ws
  | .star :: _, [] => false
  | .star :: ps, _ :: ws => spec ps ws
  | .word _ :: _, [] => false
  | .word p :: ps, w :: ws => p == w && spec ps ws

/-! ## The Crystal segment chain

A `nil` `RkIterator` is the empty word list. -/

/-- The `HashSegment` loop: `rk = rk.next` until `nil`, trying `n.match?` on each.
It never tries the empty suffix. -/
def nonEmptySuffix (f : List α → Bool) : List α → Bool
  | [] => false
  | w :: ws => f (w :: ws) || nonEmptySuffix f ws

/-- `Segment#match?` for a chain of at least one segment. -/
def segMatch [DecidableEq α] : List (Pat α) → List α → Bool
  | [], _ => false
  -- HashSegment without a successor
  | [.hash], _ => true
  -- HashSegment: `n.match?(rk)`, then every later non-empty iterator
  | .hash :: n :: ps, rk =>
    segMatch (n :: ps) rk || match rk with
      | [] => false
      | _ :: rest => nonEmptySuffix (segMatch (n :: ps)) rest
  -- StarSegment
  | [.star], rk => match rk with
    | [] => false
    | _ :: rest => rest.isEmpty
  | .star :: n :: ps, rk => match rk with
    | [] => false
    | _ :: rest => segMatch (n :: ps) rest
  -- StringSegment
  | [.word s], rk => match rk with
    | [] => false
    | w :: rest => w == s && rest.isEmpty
  | .word s :: n :: ps, rk => match rk with
    | [] => false
    | w :: rest => w == s && segMatch (n :: ps) rest

/-- `TopicBindingKey#matches?`: `false` for a `nil` iterator or an empty chain. -/
def keyMatches [DecidableEq α] (key : List (Pat α)) (rk : List α) : Bool :=
  !rk.isEmpty && segMatch key rk

/-- A non-empty pattern that accepts no words starts with `#`, so it accepts anything.
This is why `HashSegment` may skip the empty suffix. -/
theorem spec_nil_all [DecidableEq α] (p : Pat α) (ps : List (Pat α))
    (h : spec (p :: ps) [] = true) (ws : List α) : spec (p :: ps) ws = true := by
  cases p with
  | hash =>
    simp only [spec, anySuffix] at h ⊢
    exact anySuffix_of_nil _ h ws
  | star => simp [spec] at h
  | word _ => simp [spec] at h

theorem anySuffix_eq (f : List α → Bool) (hf : f [] = true → ∀ ws, f ws = true)
    (w : α) (ws : List α) :
    anySuffix f (w :: ws) = (f (w :: ws) || nonEmptySuffix f ws) := by
  induction ws generalizing w with
  | nil =>
    cases h : f []
    · simp [anySuffix, nonEmptySuffix, h]
    · simp [anySuffix, nonEmptySuffix, h, hf h]
  | cons v vs ih => rw [anySuffix, ih v, nonEmptySuffix]

theorem beq_symm [DecidableEq α] (a b : α) : (a == b) = (b == a) := by
  by_cases h : a = b
  · subst h; rfl
  · have h' : b ≠ a := Ne.symm h
    rw [beq_false_of_ne h, beq_false_of_ne h']

theorem segMatch_spec [DecidableEq α] (ps : List (Pat α)) (hps : ps ≠ []) (rk : List α) :
    segMatch ps rk = spec ps rk := by
  induction ps generalizing rk with
  | nil => contradiction
  | cons p ps ih =>
    cases ps with
    | nil =>
      cases p with
      | hash => simp [segMatch, spec, anySuffix_of_nil]
      | star => cases rk <;> simp [segMatch, spec]
      | word s => cases rk <;> simp [segMatch, spec, beq_symm s]
    | cons n ps =>
      have ih := funext (ih (by simp))
      cases p with
      | hash =>
        cases rk with
        | nil => simp [segMatch, spec, anySuffix, ih]
        | cons w rest =>
          simp only [segMatch, spec, ih]
          rw [anySuffix_eq _ (spec_nil_all n ps)]
      | star => cases rk <;> simp [segMatch, spec, ih]
      | word s => cases rk <;> simp [segMatch, spec, ih, beq_symm s]

theorem keyMatches_spec [DecidableEq α] (key : List (Pat α)) (hkey : key ≠ [])
    (rk : List α) (hrk : rk ≠ []) : keyMatches key rk = spec key rk := by
  cases rk with
  | nil => contradiction
  | cons => simp [keyMatches, segMatch_spec key hkey]

/-! ## Splitting the routing key -/

/-- Splitting on `.`, keeping empty words: `"a."` is `["a", ""]`. -/
def split : List Char → List (List Char)
  | [] => [[]]
  | c :: cs =>
    if c = '.' then [] :: split cs
    else match split cs with
      | w :: ws => (c :: w) :: ws
      | [] => [[c]]

/-- `RkIterator` as in the source, scanning for the next dot with the current
word reversed in `cur`. A dot followed by nothing ends the iteration, because
`#next` returns `nil` once `@raw.empty?`. -/
def rkWords (cur : List Char) : List Char → List (List Char)
  | [] => [cur.reverse]
  | ['.'] => [cur.reverse]
  | c :: rest => if c = '.' then cur.reverse :: rkWords [] rest else rkWords (c :: cur) rest

theorem rkWords_drops_trailing_word :
    rkWords [] "a.".toList = [['a']] ∧ split "a.".toList = [['a'], []] := by
  decide

/-- The fixed iterator: an empty remainder after a dot is still a word. -/
def rkWordsFixed (cur : List Char) : List Char → List (List Char)
  | [] => [cur.reverse]
  | c :: rest => if c = '.' then cur.reverse :: rkWordsFixed [] rest else rkWordsFixed (c :: cur) rest

theorem rkWordsFixed_split' (cur cs : List Char) :
    ∃ w ws, split cs = w :: ws ∧ rkWordsFixed cur cs = (cur.reverse ++ w) :: ws := by
  induction cs generalizing cur with
  | nil => exact ⟨[], [], rfl, by simp [rkWordsFixed]⟩
  | cons c cs ih =>
    by_cases hc : c = '.'
    · obtain ⟨w, ws, hs, hr⟩ := ih []
      refine ⟨[], w :: ws, by simp [split, hc, hs], ?_⟩
      simp [rkWordsFixed, hc, hr]
    · obtain ⟨w, ws, hs, hr⟩ := ih (c :: cur)
      refine ⟨c :: w, ws, by simp [split, hc, hs], ?_⟩
      simp [rkWordsFixed, hc, hr]

theorem rkWordsFixed_split (raw : List Char) : rkWordsFixed [] raw = split raw := by
  obtain ⟨w, ws, hs, hr⟩ := rkWordsFixed_split' [] raw
  simp [hs, hr]

end AmqpTopic
