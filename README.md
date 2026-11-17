# Food Additive Lens

Research materials and Swift source for the Food Additive Lens iOS application, associated with the paper *Food Additive Lens: An on-device AI application for real-time science-based consumer education on food additives using retrieval-augmented generation*.

## Repository layout

| Folder | Contents |
| --- | --- |
| `ios/` | Swift application source (`code of Food Additive Lens.swift`) |
| `notebooks/` | Food-category classification, additive identification, embedding, and explanation-quality analysis notebooks |
| `data/` | `branded_food_short.csv` and `FoodSubstances_cleaned_v2.csv` |
| `evaluation/` | Consumer and student explanation-quality assessment spreadsheets |

The notebooks contain research and validation work; the Swift file is application source, not a complete Xcode project. The Swift code refers to bundled CSV resources such as `branded_food_short_sample.csv` and `FoodSubstancesCFR.csv` that are not included here. Set up the expected app resources and paths before building or running it. Notebook data paths may also need to be adapted to your environment.

CSV files are covered by the repository's Git LFS rule in `.gitattributes`. Ensure Git LFS is installed when cloning or committing changes to them.

## License

See [LICENSE](LICENSE) for the repository license.
