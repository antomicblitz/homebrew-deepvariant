# Homebrew formula for DeepVariant — macOS ARM64 native build
#
# Installs pre-built DeepVariant binaries with tensorflow-macos + tensorflow-metal
# for Metal GPU-accelerated variant calling on Apple Silicon.
#
# This formula is intended for a custom tap (antomicblitz/homebrew-deepvariant),
# NOT homebrew-core, because it ships pre-built Bazel binaries.
#
# Usage:
#   brew tap antomicblitz/deepvariant
#   brew install deepvariant
#
class Deepvariant < Formula
  desc "Deep learning variant caller for genomic data (Apple Silicon native)"
  homepage "https://github.com/antomicblitz/deepvariant-macos-arm64-metal"
  url "https://github.com/antomicblitz/deepvariant-macos-arm64-metal/releases/download/v1.9.0/deepvariant-1.9.0-macos-arm64.tar.gz"
  sha256 "30b0bfc93634bd869ec624ed30d67a20c60a1861c833430eb24be3594fa89bd9"
  license "BSD-3-Clause"
  version "1.9.0"

  depends_on arch: :arm64
  depends_on :macos
  depends_on "python@3.10"
  depends_on "parallel"
  depends_on "samtools" => :recommended

  def install
    python = Formula["python@3.10"].opt_bin/"python3.10"
    venv = libexec/"venv"

    # Create a dedicated virtualenv
    system python, "-m", "venv", venv
    venv_pip = venv/"bin/pip"
    venv_python = venv/"bin/python3"

    # Upgrade pip
    system venv_pip, "install", "-q", "--upgrade", "pip"

    # Pin NumPy to 1.x FIRST — tensorflow-macos 2.13.1 requires NumPy 1.x.
    # NumPy 2.x causes AttributeError (_ARRAY_API not found).
    system venv_pip, "install", "-q", "numpy>=1.22,<=1.24.3"

    # TensorFlow for macOS ARM64
    # tensorflow-metal provides ~4.25x speedup for call_variants via Metal GPU
    system venv_pip, "install", "-q", "tensorflow-macos==2.13.1"
    system venv_pip, "install", "-q", "tensorflow-metal==1.0.0"

    # Packages that would pull in regular 'tensorflow' — install without deps
    system venv_pip, "install", "-q", "--no-deps", "tensorflow-hub==0.14.0"
    system venv_pip, "install", "-q", "--no-deps", "tensorflow-model-optimization==0.7.5"
    system venv_pip, "install", "-q", "--no-deps", "tf-models-official==2.13.1"

    # tf-models-official runtime deps
    system venv_pip, "install", "-q",
      "tensorflow-datasets", "gin-config", "seqeval",
      "opencv-python-headless>=4.5", "tf-slim", "sacrebleu", "pyyaml"

    # DeepVariant Python dependencies
    system venv_pip, "install", "-q",
      "absl-py", "parameterized", "contextlib2", "etils",
      "typing_extensions", "importlib_resources",
      "sortedcontainers==2.1.0", "intervaltree==3.1.0",
      "mock>=2.0.0", "ml_collections", "clu==0.0.9",
      "protobuf==4.21.9", "requests>=2.18",
      "joblib", "psutil", "ipython",
      "pandas==1.3.4", "Pillow==9.5.0", "pysam==0.20.0",
      "scikit-learn==1.0.2", "jax==0.4.35", "markupsafe==2.1.1"
    system venv_pip, "install", "-q", "--ignore-installed", "PyYAML"

    # Re-pin NumPy (safety net)
    system venv_pip, "install", "-q", "--force-reinstall", "numpy>=1.22,<=1.24.3"

    # Install pre-built binaries
    (libexec/"bin").install Dir["bin/*"]
    (libexec/"scripts").install Dir["scripts/*"]

    # Make all binaries executable
    (libexec/"bin").glob("*").each do |f|
      f.chmod(0755) unless f.extname == ".zip"
    end

    # Create wrapper scripts for the main DeepVariant binaries
    dv_bins = %w[
      make_examples call_variants postprocess_variants
      vcf_stats_report show_examples fast_pipeline
    ]
    dv_bins.each do |name|
      bin_path = libexec/"bin"/name
      next unless bin_path.exist?

      if name == "fast_pipeline"
        # Native C++ binary — run directly
        bin.install_symlink bin_path
      else
        # Python zip binary — run via venv python
        (bin/name).write <<~BASH
          #!/bin/bash
          exec "#{venv_python}" "#{bin_path}" "$@"
        BASH
        (bin/name).chmod(0755)
      end
    end

    # run_deepvariant wrapper (the main pipeline runner)
    (bin/"run_deepvariant").write <<~BASH
      #!/bin/bash
      exec "#{venv_python}" "#{libexec}/scripts/run_deepvariant.py" "$@"
    BASH
    (bin/"run_deepvariant").chmod(0755)

    # run_deeptrio wrapper
    if (libexec/"scripts/run_deeptrio.py").exist?
      (bin/"run_deeptrio").write <<~BASH
        #!/bin/bash
        exec "#{venv_python}" "#{libexec}/scripts/run_deeptrio.py" "$@"
      BASH
      (bin/"run_deeptrio").chmod(0755)
    end

    # Model download helper
    if (libexec/"scripts/deepvariant-download-model").exist?
      (bin/"deepvariant-download-model").write <<~BASH
        #!/bin/bash
        exec "#{libexec}/scripts/deepvariant-download-model" "$@"
      BASH
      (bin/"deepvariant-download-model").chmod(0755)
    end
  end

  def post_install
    # Download the default WGS model if not already present
    model_dir = var/"deepvariant/models/wgs"
    unless model_dir.exist?
      ohai "Downloading WGS model (this only happens once)..."
      system bin/"deepvariant-download-model", "WGS"
    end
  end

  def caveats
    <<~EOS
      DeepVariant v#{version} for macOS ARM64 (Apple Silicon)

      Metal GPU acceleration is enabled (tensorflow-metal), providing
      ~4.25x speedup for call_variants inference.

      Models are stored in: #{var}/deepvariant/models/
      To download additional models:
        deepvariant-download-model WES
        deepvariant-download-model PACBIO
        deepvariant-download-model ONT_R104

      Quick test:
        # Download test data and run a small variant calling job
        deepvariant-quicktest

      Usage:
        run_deepvariant \\
          --model_type WGS \\
          --ref reference.fasta \\
          --reads input.bam \\
          --output_vcf output.vcf \\
          --num_shards $(sysctl -n hw.perflevel0.logicalcpu)
    EOS
  end

  test do
    # Verify Python environment and TensorFlow import
    venv_python = libexec/"venv/bin/python3"
    system venv_python, "-c", "import tensorflow as tf; print(tf.__version__)"

    # Verify Metal GPU detection
    output = shell_output("#{venv_python} -c 'import tensorflow as tf; print(len(tf.config.list_physical_devices(\"GPU\")))'")
    assert_match(/[0-9]+/, output.strip)

    # Verify binaries exist and are runnable
    assert_predicate bin/"make_examples", :executable?
    assert_predicate bin/"call_variants", :executable?
    assert_predicate bin/"postprocess_variants", :executable?
    assert_predicate bin/"run_deepvariant", :executable?
  end
end
