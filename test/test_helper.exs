Logger.configure(level: :warning)

# HEIF/AVIF tests need a libvips built with libheif. Excluded unless VIX_TEST_HEIF is set.
# TEMPORARY: replace with a runtime capability check when HEIF coverage becomes permanent.
heif = System.get_env("VIX_TEST_HEIF") not in [nil, "", "0", "false"]
ExUnit.start(exclude: if(heif, do: [], else: [heif: true]))
