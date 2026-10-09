# Third-party notices

## Music Assistant mark

`MaIcon.qml` includes a modified rendering of the Music Assistant application
mark from [`public/favicon.svg`](https://github.com/music-assistant/frontend/blob/e3a8d7b19a6d5f46b8262e0ca202a26dc85a3aec/public/favicon.svg) in the
[`music-assistant/frontend`](https://github.com/music-assistant/frontend)
repository.

Source commit: `e3a8d7b19a6d5f46b8262e0ca202a26dc85a3aec`

The source repository is licensed under the Apache License 2.0. A complete
copy is included at [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt).

Modifications made for this plugin:

- converted the SVG path into a QML `PathSvg`;
- omitted the source icon's fixed blue background rectangle;
- made the path fill follow the active Omarchy theme;
- scaled the mark to the shell's requested icon size.

Music Assistant is a project of the Open Home Foundation. Its name and mark
are used only to identify compatibility with the service. This independent
plugin is not affiliated with or endorsed by Music Assistant or the Open Home
Foundation. The Apache License does not grant trademark permission.
