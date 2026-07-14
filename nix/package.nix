{
  lib,
  stdenv,
  nodejs_22,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
  turbo,
  makeWrapper,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "ontime";
  version = "4.10.0";

  # Build from the repo root (the flake lives there).
  src = lib.cleanSource ../.;

  nativeBuildInputs = [
    nodejs_22
    pnpm_11
    pnpmConfigHook
    turbo
    makeWrapper
  ];

  # Offline pnpm store. Regenerate with `nix build .#ontime.pnpmDeps` after
  # dependency changes and paste the reported hash.
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-8LW4ybazmmtRmy2ywMoqxkx909Dp6Hoo7fKeBEddxKI=";
  };

  env = {
    # Turbo tries to phone home / write to $HOME otherwise.
    TURBO_TELEMETRY_DISABLED = "1";
    DO_NOT_TRACK = "1";
  };

  # The repo pins `packageManager: pnpm@11.1.2`, which differs from nixpkgs'
  # pnpm_11 (${pnpm_11.version}). pnpm would otherwise try to fetch that exact
  # version from the network mid-build (which fails in the sandbox). Turbo
  # still requires the field to be present, so rewrite it to match.
  postPatch = ''
    echo "manage-package-manager-versions=false" >> .npmrc
    sed -i 's|"packageManager": "pnpm@[^"]*"|"packageManager": "pnpm@${pnpm_11.version}"|' package.json
  '';

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR

    # The offline install runs with --ignore-scripts, so the `addversion`
    # postinstall (which writes src/ONTIME_VERSION.js in the client and server)
    # never ran. Generate it here before building.
    pnpm --filter ontime-ui --filter ontime-server run addversion

    # NODE_ENV=docker is a build-time entrypoint selector, NOT a request to
    # build a container. Upstream's esbuild.js keys off it: `docker` bundles
    # the self-starting server (src/index.ts -> dist/docker.cjs), while the
    # default bundles a library entry (src/app.ts) that only exports startup
    # functions for the Electron app to drive. We want the self-starting
    # server, hence `docker`. The runtime NODE_ENV is set separately (to
    # `production` in the wrapper below); it is not baked into the bundle.
    #
    # TODO(upstream): if we upstream this Nix packaging, send a PR renaming the
    # `docker` variant to something like `standalone`/`server` (esbuild.js,
    # build:docker script, dist/docker.cjs) so the intent is clear, then update
    # the NODE_ENV value and the docker.cjs paths here.
    #
    # Use the nixpkgs turbo (on PATH) rather than the vendored binary.
    NODE_ENV=docker turbo run build --filter=ontime-server --filter=ontime-ui

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    share=$out/share/ontime
    mkdir -p $share/{server,client,external,user,html}

    # Mirror the Dockerfile layout. The server resolves its install root as
    # dirname(dirname(runningFile)), so docker.cjs must sit in $share/server
    # with client/external/user/html as siblings.
    cp -r apps/server/dist/.        $share/server/
    cp -r apps/client/build/.       $share/client/
    cp -r apps/server/src/external/. $share/external/
    cp -r apps/server/src/user/.     $share/user/
    cp -r apps/server/src/html/.     $share/html/

    mkdir -p $out/bin
    makeWrapper ${lib.getExe nodejs_22} $out/bin/ontime-server \
      --add-flags $share/server/docker.cjs \
      --set NODE_ENV production

    runHook postInstall
  '';

  meta = {
    description = "Time keeping for live events - server";
    homepage = "https://www.getontime.no/";
    license = lib.licenses.agpl3Only;
    mainProgram = "ontime-server";
    platforms = lib.platforms.linux;
  };
})
