Act as a Principal UI/UX Engineer. Your goal is to modernize and visually polish the UI of this application while keeping 100% of the existing functionality intact.

STRICT CONSTRAINTS (DO NOT VIOLATE):
1. ZERO FUNCTIONAL CHANGES: Do not modify, move, or delete any state management, event handlers, API calls, prop interfaces, routing, or business logic. 
2. DOM PRESERVATION: Do not alter the functional structure or hierarchy of components (e.g., keep form structures, button actions, and inputs working exactly as they are).
3. ISOLATED STYLING: Restrict all changes exclusively to styling (CSS, Tailwind classes, dynamic theme tokens, layout spacing, fonts, and animation wrappers).
4. UNIFORM IN BOTH IMPLEMENTATION: The two display versions of the tool (Android/Smartphone and Windows/Desktop) should be handled independently because of specificities for each displays (size, orientation,...), but keep an homogenous style and implementation.

VISUAL OBJECTIVES:
- Typography & Spacing: Improve contrast, hierarchy, line-height, and use a consistent spatial scale (padding, margins, gaps).
- Color System: Apply a clean, cohesive color palette with subtle borders, background fills, and state styles (hover, focus, active, disabled).
- Components: Polish buttons, cards, inputs, and tables with smooth transitions, modern border-radii, and elevated shadow depths. Don't forget popups.
- Micro-interactions: Add subtle hover states and focus rings for accessible interactive elements.

PROCEDURE:
1. Audit the target files first and list the exact styling changes you plan to make.
2. Refactor the styles incrementally.
3. Verify after editing that all prop types, event bindings, and data hooks remain identical to the original code, and that everything is visible, displayed correctly, within the screen, for each implementation of the app.