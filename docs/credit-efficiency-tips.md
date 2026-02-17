# Claude Code Credit Efficiency Tips

## File Structure for Minimal Credit Usage
- **CLAUDE.md** — Keep minimal (overview + current phase only)
- **docs/*.md** — Detailed docs read on-demand
- Claude Code automatically reads CLAUDE.md every turn
- Only reads other files when explicitly told

## Workflow to Reduce Credits

### 1. Start Each Work Session
Open Claude Code and say:
> "Read docs/phase1-cleanup.md. I want to work on Task 1: Create shared config module."

This loads only the context you need for the current task.

### 2. Switch Tasks
When moving to a different task, explicitly refresh context:
> "I'm done with that task. Read docs/phase1-cleanup.md again and let's move to Task 2: Fix known bugs."

### 3. Use Haiku for Simple Tasks
For straightforward edits or questions, switch to Haiku model:
- Open command palette: Ctrl+Shift+P (Windows) or Cmd+Shift+P (Mac)
- Type "Claude: Switch Model"
- Choose "claude-3-5-haiku"
- Use for: simple edits, bug fixes, single-file changes
- Switch back to Sonnet for: complex refactoring, multi-file changes, architecture decisions

### 4. Use Plan Mode for Exploration
Before starting a complex task:
> "/plan I need to refactor the Firebase initialization across all scripts"

Plan mode uses fewer credits and helps you think through the approach before writing code.

### 5. Close Large Files from Context
If you've opened a large file (like the old CLAUDE.md) and no longer need it:
> "Close all files from context. Now read docs/phase1-cleanup.md."

### 6. Batch Related Changes
Instead of multiple small interactions, describe all changes at once:
> "I need you to: 1) create config.py, 2) update master_control.py to use it, 3) update camera_server.py to use it. Do all three."

One response with 3 changes uses fewer credits than 3 separate requests.

### 7. Avoid Unnecessary Context
Don't include irrelevant files in your prompts:
- ❌ "Look at all the Python scripts and tell me..."
- ✅ "Read raspberry_pi/core/master_control.py and tell me..."

### 8. Use Search Instead of Reading
For quick lookups:
> "Search the codebase for where Firebase is initialized"

Instead of reading 5 files to find it.

## Model Selection Guide

**Haiku (cheapest):**
- Simple edits (fix typo, add logging statement)
- Single-file bug fixes
- Generating boilerplate code
- Answering factual questions about code

**Sonnet (default):**
- Multi-file refactoring
- Architecture decisions
- Complex debugging
- New feature implementation

**Opus (most expensive, rarely needed):**
- Very complex system-wide changes
- Novel algorithm design
- Critical bug investigation across entire codebase

## Credit Usage Estimates
Reading CLAUDE.md (old version) = ~3000 tokens per turn
Reading CLAUDE.md (new minimal version) = ~500 tokens per turn
Reading a phase doc on-demand = ~800 tokens (only when needed)

**Net savings: ~80% credit reduction by using new structure**
