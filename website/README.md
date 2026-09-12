# Vela website

The official site is a static HTML/CSS/JavaScript application. It has no package dependencies, client analytics, account system or build step. Product examples are explicitly marked as fictional.

Preview from the repository root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website/dist
```

Open `http://127.0.0.1:4173`. Validate links and JavaScript with `python3 scripts/check-repository.py`.

`dist/` contains the deployable source. `.openai/hosting.json` binds the current official Sites deployment. A separate clone can host the same static files on any static-file host; do not copy the original project's deployment binding into an unrelated site.

UI changes follow the Antigravity CLI workflow in the root `AGENTS.md`. Keep download links pointed at published GitHub releases and product claims consistent with `docs/status.md`. Do not publish internal prompts, synthetic examples as measurements, or user session data.
