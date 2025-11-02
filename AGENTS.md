# AGENTS.md — Reverse Engineering Notes for `libg*.so`

---

## High-Level Summary

- The binary is an **ELF shared object** (`.so`) with the usual sections (`.text`, `.rodata`, `.data`, etc.).
- It is **stripped** (no DWARF symbols observed) and relies on **embedded log strings** such as `LoginMessage::decode - ...` for ground truth of message types.
- There exists a **dense, fixed-stride registry table** that behaves like a **packet dispatcher** (PacketID → handler pointer/meta).
- We **confirmed** the canonical anchor: **packet `10100` → `LoginMessage`**.
- `LoginMessage::decode` log markers show it parses multiple device/auth fields (see §5).
- Automatic “Message ⇄ ID” mapping is possible with light disassembly/xref (objdump, Capstone, rizin/radare2, IDA/Ghidra) following the procedures below.

> **Takeaway:** We can productize a repeatable pipeline that extracts the registry block, resolves handler code locations, and links them to `*Message::decode` strings to emit a definitive CSV mapping for Coding Agents.

---

## File Format & Observations

- **Format:** ELF shared object (`.so`). Standard section layout present.
- **Symbols:** No public C++ symbols for message classes are exported; **no DWARF** debug info is visible. We navigate with **string anchors** and **tables**.
- **Strings:** `.rodata` contains numerous **log labels** like:
  - `LoginMessage::decode - open udid`
  - `LoginMessage::decode - resource sha`
  - `LoginMessage::decode - preferred language id`
  - `LoginMessage::decode - device`
  - `LoginMessage::decode - os version`
  - `LoginMessage::decode - mac address`
  - `LoginMessage::decode - udid`
  - `LoginMessage::decode - adid`
  - `LoginMessage::decode - pass token`
- **Endianness in Registry:** Packet IDs appear stored as **big-endian u16** inside 8-byte records. Associated pointers/values appear **little-endian u32**.

> **Confidence:** High for the string markers; very high for presence of a packet registry (stride and content are self-consistent).

---

## Packet Registry Table (Critical)

- **Region:** A dense, uniform table lives roughly in the range:
  - **`0x000ED400–0x000EE000` in file offsets** (exact boundaries may vary slightly).
- **Stride:** **8 bytes** per record.
- **Alignment:** The table rows become perfectly regular with a **+7 byte alignment offset** (i.e., interpret rows starting at `0x000ED400 + 7`, then every `+8`).
- **Record Layout (empirical):**
  ```
  struct Rec {
      u16 unknown;           // rec[0:2]   (endianness not relied upon)
      u16 packet_id_be;      // rec[2:4]   big-endian packet id (e.g., 0x2774 => 10100)
      u32 handler_ptr_le;    // rec[4:8]   little-endian 32-bit value; behaves like code/rodata pointer
  };
  ```

- **Known anchor:** searching for **`0x2774`** (big-endian **10100**) yields one or more registry entries within this block.
- **Neighborhood:** Packet IDs around **10100** appear in the same registry slice (can be enumerated ±N rows to map related messages in the same family).

> **Usage:** This table is the authoritative **PacketID index**. Combine with handler pointer resolution and string cross-references to get **Message ⇄ ID**.

---

## Message Type Discovery (Strings)

- Message types are consistently referenced in log strings with the form:
  ```
  <TypeName>Message::decode - <field/phase>
  ```
- Extracting strings and grepping for `([A-Za-z0-9_]+)Message::decode` yields a **finite set of message type names**; these are the canonical labels to map with Packet IDs.

> **Examples captured:** `LoginMessage`, `LoginOkMessage`, `LoginFailedMessage`, `ClientCapabilitiesMessage`, etc. (Total unique types: **~48–50** observed via string scan; exact count depends on build.)

---

## `LoginMessage::decode` (Packet 10100)

- **Mapping:** **`10100 (0x2774)` → `LoginMessage`** (confirmed).
- **Decode Flow (from log markers):** the function reads, at minimum, the following fields:
  - `open_udid` (string)
  - `resource_sha` (string; likely hex or bytes for a resource pack/fingerprint)
  - `preferred_language_id` (integer, likely varint)
  - `device` (string)
  - `os_version` (string)
  - `mac_address` (string)
  - `udid` (string)
  - `adid` (Advertising ID, string)
  - `pass_token` (string; Supercell ID / session credential)
- **Implication:** The library implements the wire protocol’s **client login** handshake, with device/environment metadata for anti-abuse/fraud and resource compatibility checks.

---

## Development

- Commit only hunks with actual code changes. All code should use CRLF line endings and existing whitespace should be preserved; never reformat untouched lines.
- Run `dotnet test` to ensure all tests pass whenever C# source files (`*.cs`) are modified. Skip this step if no C# files change.
- Be patient with long-running tests and avoid aborting them early; some may take several minutes to complete.
- After changing source code, run `dotnet build` from the repository root.
- Conventional Commits are required for commit messages.
- Commit messages must include a scope after the type, e.g., `docs(readme): ...`.
- Use only the following Conventional Commit types:
  - `feat` — Features
  - `fix` — Bug Fixes
  - `perf` — Performance Improvements
  - `deps` — Dependencies
  - `revert` — Reverts
  - `docs` — Documentation
  - `style` — Styles
  - `chore` — Miscellaneous Chores
  - `refactor` — Code Refactoring
  - `test` — Tests
  - `build` — Build System
  - `ci` — Continuous Integration
- Commit bodies are required and must include a brief note about any observable behavior change.
- Use the `fix` or `feat` type only when your changes modify the proxy code in `./src`. For documentation, CI, or other unrelated updates, choose a more appropriate type such as `docs` or `chore`.
- Append a [gitmoji](https://gitmoji.dev/specification) after the commit scope, e.g., `feat(api): ✨ add new endpoint`.
- Pull request titles should follow the same Conventional Commits format.