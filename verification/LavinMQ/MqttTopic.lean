/-!
# MQTT 3.1.1 topic filter matching (§4.7)

`#` matches the parent level and any number of child levels [MQTT-4.7.1-2],
`+` matches exactly one level, and a filter starting with a wildcard never
matches a topic starting with `$` [MQTT-4.7.2-1].

LavinMQ matches filters in three places. Each is modelled here per filter,
following the source branch by branch:

* `TopicRuleSegment` (permission rules)
* `SubscriptionTree#each_entry` (routing a publish to subscribers)
* `TopicTree#each` (retained messages delivered on subscribe)

Proven here:
* `TopicRuleSegment` equals the specification
* `SubscriptionTree` and `TopicTree` miss the parent level for `#` and match
  `$` topics with leading wildcards; their fixed versions equal the specification
-/

namespace MqttTopic

inductive Level (α : Type) where
  | hash
  | plus
  | word (w : α)
  deriving DecidableEq

variable {α : Type} [DecidableEq α]

/-- §4.7.1. `#` is only valid as the last level, and matches whatever remains. -/
def spec : List (Level α) → List α → Bool
  | [], ts => ts.isEmpty
  | .hash :: _, _ => true
  | .plus :: _, [] => false
  | .plus :: fs, _ :: ts => spec fs ts
  | .word _ :: _, [] => false
  | .word w :: fs, t :: ts => w == t && spec fs ts

def wildcardFirst : List (Level α) → Bool
  | .hash :: _ | .plus :: _ => true
  | _ => false

/-- §4.7.2 on top of §4.7.1, with `dollar t` telling whether a level starts with `$`. -/
def subscriptionSpec (dollar : α → Bool) (f : List (Level α)) (ts : List α) : Bool :=
  spec f ts && !(wildcardFirst f && ts.head?.any dollar)

theorem beq_symm (a b : α) : (a == b) = (b == a) := by
  by_cases h : a = b
  · subst h; rfl
  · rw [beq_false_of_ne h, beq_false_of_ne (Ne.symm h)]

/-! ## `TopicRuleSegment` -/

/-- Each segment takes one token and hands the rest on through `match_rest?`,
which requires the topic to end when there is no successor. -/
def ruleMatch : List (Level α) → List α → Bool
  | [], ts => ts.isEmpty
  | .hash :: _, _ => true
  | .plus :: fs, ts => match ts with
    | [] => false
    | _ :: ts => ruleMatch fs ts
  | .word s :: fs, ts => match ts with
    | [] => false
    | t :: ts => t == s && ruleMatch fs ts

theorem ruleMatch_spec (f : List (Level α)) (ts : List α) : ruleMatch f ts = spec f ts := by
  induction f generalizing ts with
  | nil => rfl
  | cons l fs ih =>
    cases l <;> cases ts <;> simp [ruleMatch, spec, ih, beq_symm]

/-! ## `SubscriptionTree` -/

/-- One subscription's path through `each_entry`: `@leafs` are yielded when the
topic is exhausted, `@wildcard_rest` only while a level remains. Filters
without wildcards go through `@non_wildcards` instead, see `literal_spec`. -/
def treeMatch : List (Level α) → List α → Bool
  | [], ts => ts.isEmpty
  | .hash :: _, [] => false
  | .hash :: _, _ :: _ => true
  | .plus :: _, [] => false
  | .plus :: fs, _ :: ts => treeMatch fs ts
  | .word _ :: _, [] => false
  | .word w :: fs, t :: ts => t == w && treeMatch fs ts

theorem treeMatch_misses_parent :
    treeMatch [.word 1, .hash] [1] = false ∧ spec [.word 1, .hash] [1] = true := by
  decide

/-- `@wildcard_rest` is also yielded when the topic is exhausted. -/
def treeMatchFixed : List (Level α) → List α → Bool
  | [], ts => ts.isEmpty
  | .hash :: _, _ => true
  | .plus :: _, [] => false
  | .plus :: fs, _ :: ts => treeMatchFixed fs ts
  | .word _ :: _, [] => false
  | .word w :: fs, t :: ts => t == w && treeMatchFixed fs ts

theorem treeMatchFixed_spec (f : List (Level α)) (ts : List α) :
    treeMatchFixed f ts = spec f ts := by
  induction f generalizing ts with
  | nil => rfl
  | cons l fs ih =>
    cases l <;> cases ts <;> simp [treeMatchFixed, spec, ih, beq_symm]

/-- `@non_wildcards` compares the whole filter with the topic, which is the
specification for a filter of plain words. -/
theorem literal_spec (ws ts : List α) : spec (ws.map .word) ts = (ws == ts) := by
  induction ws generalizing ts with
  | nil => cases ts <;> rfl
  | cons w ws ih =>
    cases ts with
    | nil => rfl
    | cons t ts => simp [spec, ih]

/-- `each_entry` from the root, skipping the root's `@wildcard_rest` and `@plus`
for a `$` topic. -/
def treeEntry (dollar : α → Bool) (f : List (Level α)) (ts : List α) : Bool :=
  match ts with
  | t :: _ => if dollar t && wildcardFirst f then false else treeMatchFixed f ts
  | [] => treeMatchFixed f ts

theorem treeEntry_spec (dollar : α → Bool) (f : List (Level α)) (ts : List α) :
    treeEntry dollar f ts = subscriptionSpec dollar f ts := by
  cases ts with
  | nil => simp [treeEntry, subscriptionSpec, treeMatchFixed_spec]
  | cons t ts =>
    simp only [treeEntry, subscriptionSpec, treeMatchFixed_spec, List.head?_cons,
      Option.any_some]
    cases dollar t <;> cases wildcardFirst f <;> simp

theorem dollar_needs_root_check :
    treeMatchFixed [.hash] [0] = true ∧ subscriptionSpec (· == 0) [.hash] [0] = false := by
  decide

/-! ## `TopicTree` (retained messages)

A stored topic `t :: ts` is `@leafs[t]` when `ts` is empty and lives under
`@sublevels[t]` otherwise, so every branch of `#each` looks one level ahead. -/

/-- `#each` as in the source. `#` yields everything below the node, which holds
topics with at least one more level. -/
def retainMatch : List (Level α) → List α → Bool
  | [], _ => false
  | .hash :: _, ts => !ts.isEmpty
  | [.plus], ts => ts.length == 1
  | .plus :: f :: fs, ts => match ts with
    | _ :: t :: ts => retainMatch (f :: fs) (t :: ts)
    | _ => false
  | [.word w], ts => ts == [w]
  | .word w :: f :: fs, ts => match ts with
    | t :: t2 :: ts => t == w && retainMatch (f :: fs) (t2 :: ts)
    | _ => false

theorem retainMatch_misses_parent :
    retainMatch [.word 1, .hash] [1] = false ∧ spec [.word 1, .hash] [1] = true := by
  decide

/-- Before descending, a `#` next in the filter also takes the leaf itself. -/
def retainMatchFixed : List (Level α) → List α → Bool
  | [], _ => false
  | .hash :: _, ts => !ts.isEmpty
  | [.plus], ts => ts.length == 1
  | .plus :: f :: fs, ts => match ts with
    | [_] => f == .hash
    | _ :: t :: ts => retainMatchFixed (f :: fs) (t :: ts)
    | [] => false
  | [.word w], ts => ts == [w]
  | .word w :: f :: fs, ts => match ts with
    | [t] => t == w && f == .hash
    | t :: t2 :: ts => t == w && retainMatchFixed (f :: fs) (t2 :: ts)
    | [] => false

/-- Holds for every stored topic, as `TopicTree#insert` rejects empty ones. -/
theorem retainMatchFixed_spec (f : List (Level α)) (ts : List α) (hts : ts ≠ []) :
    retainMatchFixed f ts = spec f ts := by
  induction f generalizing ts with
  | nil => cases ts <;> simp_all [retainMatchFixed, spec]
  | cons l fs ih =>
    cases ts with
    | nil => contradiction
    | cons t ts =>
      cases l with
      | hash => simp [retainMatchFixed, spec]
      | plus =>
        cases fs with
        | nil => cases ts <;> simp [retainMatchFixed, spec]
        | cons f fs =>
          cases ts with
          | nil => cases f <;> simp [retainMatchFixed, spec]
          | cons t2 ts => simp [retainMatchFixed, spec, ih]
      | word w =>
        cases fs with
        | nil => cases ts <;> simp [retainMatchFixed, spec, beq_symm]
        | cons f fs =>
          cases ts with
          | nil => cases f <;> simp [retainMatchFixed, spec, beq_symm]
          | cons t2 ts => simp [retainMatchFixed, spec, ih, beq_symm]

/-- Delivery on subscribe: the root skips `$` levels for a wildcard-first filter. -/
def retainEntry (dollar : α → Bool) (f : List (Level α)) (ts : List α) : Bool :=
  match ts with
  | t :: _ => if dollar t && wildcardFirst f then false else retainMatchFixed f ts
  | [] => false

theorem retainEntry_spec (dollar : α → Bool) (f : List (Level α)) (ts : List α)
    (hts : ts ≠ []) : retainEntry dollar f ts = subscriptionSpec dollar f ts := by
  cases ts with
  | nil => contradiction
  | cons t ts =>
    simp only [retainEntry, subscriptionSpec, retainMatchFixed_spec f _ hts,
      List.head?_cons, Option.any_some]
    cases dollar t <;> cases wildcardFirst f <;> simp

end MqttTopic
