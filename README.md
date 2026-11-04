# IngeTrazo SketchUp Adapter Lab

> **Experimental — needs tuning.** The adapter does not make every SketchUp plugin compatible. Issues and pull requests are welcome.

![1001bit Hip Roof test in IngeTrazo, with the plugin dialog and model geometry visible](assets/ingetrazo-1001bit-hip-roof.jpg)

_Reference capture: 1001bit Hip Roof running in the IngeTrazo adapter._

The adapter explores how SketchUp Ruby extensions can work inside IngeTrazo. Some tools run, while geometry, ownership and document behavior still need careful tuning. Encrypted RBE extensions are not supported.

## GitHub Pages

[Open the project landing page](https://hamzah1985.github.io/sketchup-adapter/).

The workflow in `.github/workflows/pages.yml` deploys the repository root when `main` changes and on manual runs.

## Contributing

Report reproducible behavior in [Issues](https://github.com/hamzah1985/sketchup-adapter/issues) or submit a [Pull Request](https://github.com/hamzah1985/sketchup-adapter/pulls). Include the plugin and version, adapter revision, exact steps, expected result and observed result. Please do not upload licensed plugin files, activation data or private models.

## Repository files

- `index.html` — project status, known gaps, test snapshot and contribution instructions
- `styles.css` — responsive styling
- `assets/` — logo and reference screenshot
