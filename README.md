# IngeTrazo SketchUp Adapter Lab

A public landing page for the experimental SketchUp Ruby adapter for IngeTrazo. The adapter needs tuning: some plugin workflows fail, encrypted RBE extensions are unsupported, and pull requests are welcome.

The site is plain HTML and CSS. Its reference image is a user-provided capture of an IngeTrazo adapter test session. No plugin package or activation data is included.

## GitHub Pages

The workflow in `.github/workflows/pages.yml` deploys the repository root whenever `main` changes and on manual runs. In repository settings, choose **Pages → Build and deployment → Source → GitHub Actions**. GitHub publishes the site at `https://hamzah1985.github.io/sketchup-adapter/` after the workflow succeeds.

## Content

- `index.html` — project status, known gaps, test snapshot and contribution instructions
- `styles.css` — responsive styling
- `assets/` — logo and the supplied reference screenshot
