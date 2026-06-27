# Product

## Register

product

## Users

Skillui is for macOS developers who install skills from skills.sh across several AI coding agents and many project worktrees. They use it while maintaining local development environments, checking whether project-local skills drift from upstream, and keeping shared global skills current without opening each agent configuration manually.

## Product Purpose

Skillui gives one trustworthy view of installed agent skills: global skills, project-local skills, symlinked shared skills, external links, missing worktree installs, and upstream update status. Success means a developer can glance at the menu bar, understand whether anything needs action, and update skills or inspect project state without privacy prompts, account setup, or hidden background mutation.

## Brand Personality

Quiet, exacting, developer-native. The app should feel like a well-made macOS utility: compact, transparent about what it is doing, and more interested in accuracy than spectacle.

## Anti-references

Avoid marketing-style SaaS dashboards, oversized hero language, decorative gradients, mascot branding, vague "AI workflow" visuals, and any UI that obscures whether a skill is global, project-owned, symlinked, or untracked. Avoid surprise scans of personal folders and avoid update checks that mutate local skill installs.

## Design Principles

- Lead with the actionable signal: updates, rate limits, missing worktree skills, and CLI failures must be visible before decorative metadata.
- Preserve trust through explainability: every badge or disabled state should map to a clear provenance, path, source, or GitHub response.
- Stay native to macOS: use system colors, system controls, standard windows, Settings, menu commands, and predictable Finder/GitHub affordances.
- Keep density useful: this is a maintenance tool, so compact tables and menu rows are appropriate when labels, sorting, and empty states stay readable.
- Respect privacy by design: default scans must stay inside development roots and protected personal folders must remain excluded.

## Accessibility & Inclusion

Target WCAG AA contrast where custom color is used, preserve keyboard and VoiceOver access to row actions, respect reduced motion, and keep status meaning available through labels/help text rather than color alone. The app should remain usable in light and dark mode and with a GitHub rate limit or no network.
