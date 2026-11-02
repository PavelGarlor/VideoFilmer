# Third-party material

| What | Where | Licence | Source |
|---|---|---|---|
| **brag** and **brag-slim** skills (code and docs) | `.claude/skills/brag`, `.claude/skills/brag-slim` | MIT, © 2026 Shunit Haviv Hakimi (`LICENSE` inside each folder) | [latent-spaces/brag](https://github.com/latent-spaces/brag) @ `669ab92` |
| Music in brag ("Happy Beats / Business Moves" Vol. 1, 9, 10, 11, 12) | `.claude/skills/brag/assets/music` | CC BY 4.0. Credit when used: *"Music: Sascha Ende, ende.app (CC BY 4.0)"* | [ende.app](https://ende.app/en) |
| Sound effects in brag | `.claude/skills/brag/assets/sfx` | Kenney assets (CC0) | [kenney.nl](https://kenney.nl/) |
| HyperFrames skills | enabled as a plugin, not copied | Apache-2.0 | [heygen-com/hyperframes](https://github.com/heygen-com/hyperframes) |
| Remotion agent skills | optional, installed by `./setup.sh --with-remotion`, not copied | See repo; Remotion itself needs a company licence for teams > 3 | [remotion-dev/skills](https://github.com/remotion-dev/skills) |
| Fonts named in the brand kit (Plus Jakarta Sans, DM Sans, Fraunces) | not bundled | SIL Open Font License | Google Fonts |

To update brag: copy `skills/brag` and `skills/brag-slim` from a newer checkout of latent-spaces/brag over the folders above and update the commit here.
