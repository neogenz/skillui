# Design

## Identity

Skillui is a native macOS menu-bar utility. The visual system should read as practical developer tooling: restrained, compact, and precise. The app icon carries the only expressive brand moment; product screens use system vocabulary.

## Color

- Surfaces use semantic macOS colors, especially `.textBackgroundColor`, `.fill.quaternary`, `.separatorColor`, and label colors.
- Amber is the primary action/update color and should be reserved for actionable update states.
- Green is limited to positive status confirmation. Yellow is limited to warnings and rate-limit/error hints.
- Avoid broad decorative color fields; color should clarify state or provenance.

## Typography

- Use the system font throughout.
- Favor compact product UI sizes: 10-14 pt in the menu panel, standard table and form sizing in dashboard/settings.
- Use monospaced text only for hashes, versions, and technical identifiers.
- Avoid display typography and fluid type scales.

## Components

- Menu panel: fixed-width, self-sizing, with header, scrollable content, and footer actions.
- Dashboard: source-list navigation plus dense table. Use standard `NavigationSplitView`, `Table`, toolbar buttons, searchable filtering, and context menus.
- Settings: grouped macOS form with direct controls and short explanatory captions.
- Update window: native utility window with release notes, version metadata, and explicit actions: Download, Skip for now, Later.
- Cards are allowed only for grouped rows in the menu panel; do not nest cards.

## Layout

- Keep the panel glanceable: most important action at the top, secondary scopes below, footer for navigation.
- Keep dashboard rows sortable and scannable; do not replace tables with decorative card grids.
- Long paths and source names should truncate head or tail appropriately and expose full values through help/context menus.

## Motion

- Use short state transitions only for hover/status feedback.
- Respect reduced motion.
- Avoid ornamental page-load animations.

## Accessibility

- Every icon-only action needs a help label.
- Status must be understandable without color alone.
- Empty and error states should name the next useful action.
- Text must remain readable in light and dark mode.
