# SpaceMinerGame

Godot 4.7.1 prototype for a modular, grid-based spacecraft construction interface intended to support player ships, asteroid authoring, and enemy ship authoring.

## First-pass ship builder

- 3D construction grid with stronger opacity below the currently selected logical Z level.
- D-pad movement across the horizontal plane and separate vertical level controls.
- Desktop defaults: WASD or arrow keys for the D-pad, E/Q for vertical movement, Tab for the parts drawer, and Escape for menu/back/resume.
- Mobile on-screen controls are shown by default; desktop on-screen controls are hidden unless enabled in Settings > Controls.
- Drag the viewport to orbit the camera. Use the mouse wheel or a two-touch pinch to zoom.
- Collapsible, draggable/scrollable parts drawer with procedural starter pieces: cube, half sphere, pyramid, small slope, even roof, and large slope.
- While the parts drawer is open, the D-pad rotates the selected part in 90-degree increments and side bumpers move one item at a time through the part list.
- Parts support named color slots. The roof exposes two independent color regions as a first-pass validation of the multi-region material path.
- Center D-pad / Space places the current piece. Delete removes the piece anchored at the current cursor.
- Settings menu with Resume, Display, Controls, and Exit. Display supports System/Light/Dark and reads the OS preference in System mode.
- Controls menu allows every keyboard action to be rebound, including primary and alternate D-pad bindings.

## Build

The GitHub Actions workflow follows the SandGame prototype pattern: it installs Godot 4.7.1 and export templates, imports/compiles the project, runs an 8-second headless smoke test, exports a Windows executable, and uploads the executable as a workflow artifact.
