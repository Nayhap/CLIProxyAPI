# Nayhap fork of CLI Proxy API

This fork carries no source changes. It adds one workflow,
`.github/workflows/nayhap-image.yml`, which builds each stable upstream
release from its exact tag, smoke-tests the image under the same sandbox the
Environments hosted-proxy broker uses (`smoke.sh`), and publishes it as
`ghcr.io/nayhap/cli-proxy-api:<tag>`. Published digests are recorded in
`images.json` on the `nayhap-images` branch; the Environments repository pins
one of them in `cpa/VERSION`.

Upstream workflows are disabled in this fork.
