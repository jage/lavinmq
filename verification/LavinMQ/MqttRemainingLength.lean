/-!
# MQTT 3.1.1 Remaining Length (§2.2.3)

Models `MQTT::Protocol::IO#write_remaining_length` and `#read_remaining_length`
from the `mqtt-protocol` shard, and `Packet#bytesize`, which sizes a packet from
its remaining length.

Proven here:
* the encoder emits bytes, and exactly `size n` of them (Table 2.4)
* decoding an encoding gives back the value and leaves trailing bytes untouched
* the decoder never accepts more than four bytes
* `Packet#bytesize` disagrees with the encoder at 127, 16 383 and 2 097 151
-/

namespace MqttRemainingLength

/-- Largest value the encoding can carry: 0xFF 0xFF 0xFF 0x7F. -/
def maxValue : Nat := 268435455

/-- `write_remaining_length`: seven bits per byte, least significant first,
top bit set while more bytes follow. -/
def encode (n : Nat) : List Nat :=
  if n < 128 then [n] else (n % 128 + 128) :: encode (n / 128)

/-- `read_remaining_length`, with `multiplier` and `value` as accumulators.
The shard raises once `multiplier > 128³`, i.e. before a fifth byte is read. -/
def decodeAux : List Nat → Nat → Nat → Option (Nat × List Nat)
  | [], _, _ => none
  | b :: rest, multiplier, value =>
    let value := value + b % 128 * multiplier
    if b < 128 then some (value, rest)
    else if multiplier * 128 > 128 ^ 3 then none
    else decodeAux rest (multiplier * 128) value

def decode (bytes : List Nat) : Option (Nat × List Nat) := decodeAux bytes 1 0

/-- Encoded length according to Table 2.4 of the specification. -/
def size (n : Nat) : Nat :=
  if n ≤ 127 then 1 else if n ≤ 16383 then 2 else if n ≤ 2097151 then 3 else 4

/-- `Packet#bytesize` in mqtt-protocol: fixed header byte + length field + body. -/
def packetBytesize (remainingLength : Nat) : Nat :=
  if remainingLength < 127 then remainingLength + 1 + 1
  else if remainingLength < 16383 then remainingLength + 2 + 1
  else if remainingLength < 2097151 then remainingLength + 3 + 1
  else remainingLength + 4 + 1

theorem encode_bytes (n : Nat) : ∀ b ∈ encode n, b < 256 := by
  induction n using Nat.strongRecOn with
  | _ n ih =>
    unfold encode
    split
    · simp; omega
    · intro b hb
      simp at hb
      rcases hb with rfl | hb
      · omega
      · exact ih (n / 128) (by omega) b hb

/-- Each byte past the first carries seven more bits. -/
theorem size_succ (n : Nat) (h : n ≤ maxValue) (hn : 128 ≤ n) :
    size n = size (n / 128) + 1 := by
  unfold maxValue at h; unfold size; (repeat' split) <;> omega

theorem encode_length (n : Nat) (h : n ≤ maxValue) : (encode n).length = size n := by
  induction n using Nat.strongRecOn with
  | _ n ih =>
    unfold encode
    split
    · simp [size]; omega
    · simp only [List.length_cons]
      rw [ih (n / 128) (by omega) (by unfold maxValue at *; omega), size_succ n h (by omega)]

/-- Decoding with accumulator `value` and `multiplier = 128^k` resumes a partial
decode after `k` bytes; `k + size n ≤ 4` is what keeps the fifth-byte guard quiet. -/
theorem decodeAux_encode (n k value : Nat) (rest : List Nat) (hn : n ≤ maxValue)
    (h : k + size n ≤ 4) :
    decodeAux (encode n ++ rest) (128 ^ k) value = some (value + n * 128 ^ k, rest) := by
  induction n using Nat.strongRecOn generalizing k value with
  | _ n ih =>
    unfold encode
    split
    · simp [decodeAux, Nat.mod_eq_of_lt ‹n < 128›, *]
    · have hsize := size_succ n hn (by omega)
      have hk : k + 1 + size (n / 128) ≤ 4 := by omega
      have hge : 1 ≤ size (n / 128) := by unfold size; (repeat' split) <;> omega
      have hb : ¬(n % 128 + 128 < 128) := by omega
      have hp : 128 ^ k * 128 = 128 ^ (k + 1) := (Nat.pow_succ ..).symm
      have hm : ¬(128 ^ k * 128 > 128 ^ 3) := by
        rw [hp]; exact Nat.not_lt.mpr (Nat.pow_le_pow_right (by decide) (by omega))
      simp only [List.cons_append, decodeAux, hb, hm, ite_false]
      rw [hp, ih (n / 128) (by omega) (k + 1) _ (by unfold maxValue at *; omega) (by omega)]
      have hmod : (n % 128 + 128) % 128 = n % 128 := by omega
      rw [hmod, Nat.pow_succ]
      conv => rhs; rw [← Nat.div_add_mod n 128]
      grind

theorem decode_encode (n : Nat) (rest : List Nat) (h : n ≤ maxValue) :
    decode (encode n ++ rest) = some (n, rest) := by
  have hs : size n ≤ 4 := by unfold size; (repeat' split) <;> omega
  have := decodeAux_encode n 0 0 rest h (by omega)
  simpa [decode] using this

/-- Four bytes that all carry the continuation bit are rejected before a fifth is read. -/
theorem decode_rejects_fifth_byte (b1 b2 b3 b4 : Nat) (rest : List Nat)
    (h1 : 128 ≤ b1) (h2 : 128 ≤ b2) (h3 : 128 ≤ b3) (h4 : 128 ≤ b4) :
    decode (b1 :: b2 :: b3 :: b4 :: rest) = none := by
  simp [decode, decodeAux, Nat.not_lt.mpr h1, Nat.not_lt.mpr h2, Nat.not_lt.mpr h3,
    Nat.not_lt.mpr h4]

/-- What `Packet#bytesize` should be: header byte + encoded length + body. -/
def expectedBytesize (n : Nat) : Nat := 1 + (encode n).length + n

/-- The shard counts one byte too many exactly at each size boundary. -/
theorem packetBytesize_off_by_one :
    packetBytesize 127 = expectedBytesize 127 + 1 ∧
    packetBytesize 16383 = expectedBytesize 16383 + 1 ∧
    packetBytesize 2097151 = expectedBytesize 2097151 + 1 := by
  simp [packetBytesize, expectedBytesize, encode]

/-- The corrected thresholds agree with the encoder everywhere. -/
theorem size_bytesize (n : Nat) (h : n ≤ maxValue) :
    expectedBytesize n = 1 + size n + n := by
  simp [expectedBytesize, encode_length n h]

end MqttRemainingLength
