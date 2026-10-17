// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

extension LaunchSpec {
    /// The launch macos/run.sh would make (D5): the pipeline steps, the game's arguments and the
    /// variables it exports. `LaunchSpecTests` compares this with `run.sh --print-env`.
    ///
    /// run.sh's incoming environment is, in this order of precedence (later wins): `baseEnvironment`
    /// (only its BB_*/MVK_*/ROSETTA_* variables), the launcher settings' variables, the profile's
    /// variables, `profile.environment` (the expert variables, only valid names:
    /// `ExpertVariables`). `${X:-default}` in run.sh means a non-empty value from that environment
    /// wins over the default.
    public static func make(_ inputs: LaunchInputs, baseEnvironment: [String: String] = [:]) -> LaunchSpec {
        let profile = inputs.profile
        let dirs = inputs.dirs
        // The incoming environment.
        var env = baseEnvironment.filter { item in ExpertVariables.prefixes.contains { item.key.hasPrefix($0) } }

        let settings = inputs.settings
        // window.cpp: only "1" turns fullscreen on, so the default adds nothing.
        if settings.fullscreen { env["BB_FULLSCREEN"] = "1" }
        if let display = settings.display { env["BB_DISPLAY"] = String(display) }
        if let gamepad = settings.gamepad { env["BB_GAMEPAD"] = gamepad }
        if let language = settings.gameLanguage { env["BB_LANGUAGE"] = language }
        if !settings.skipNetworkChoice { env["BB_SKIP_NETWORK_CHOICE"] = "0" }

        env["BB_FPS"] = profile.frameRate.rawValue
        // The chosen built-in patches (BB_PATCHES); an expert BB_PATCHES below wins.
        if !inputs.patchExtras.isEmpty { env["BB_PATCHES"] = inputs.patchExtras }
        if let size = profile.renderResolution { env["BB_RENDER_RES"] = size }
        switch profile.renderer {
        case .automatic: break
        case .metal: env["BB_RENDERER"] = "metal"
        case .vulkan: env["BB_RENDERER"] = "vulkan"
        }
        env["BB_GAME_DIR"] = inputs.gameDir.path
        for (name, value) in ExpertVariables.valid(profile.environment) { env[name] = value }

        /// run.sh's `${NAME:-default}`: an empty variable counts as unset.
        func value(_ name: String, _ fallback: String) -> String {
            if let v = env[name], !v.isEmpty { return v }
            return fallback
        }
        func has(_ name: String) -> Bool { !(env[name] ?? "").isEmpty }

        // Paths (run.sh: data, out, BB_CONFIG, user, game).
        let out = inputs.preparedDir.path
        let ini = value("BB_CONFIG", dirs.iniFile.path)
        env["BB_CONFIG"] = ini
        // D11: own saves are a separate --user root, the GPU cache stays in the shared one.
        let user = value("BB_USER_DIR", profile.ownSaves ? dirs.profileUserDir(profile.id).path : dirs.userDir.path)
        env["BB_GPU_USER_DIR"] = value("BB_GPU_USER_DIR", profile.ownSaves ? dirs.userDir.path : user)
        let game = value("BB_GAME_DIR", inputs.gameDir.path)
        // run.sh's mods step: the game runs from the overlay, the image steps read the game.
        let app0 = inputs.modGame?.path ?? game

        // Renderer: Metal on Apple silicon with macOS 15 or newer.
        if !has("BB_RENDERER") {
            env["BB_RENDERER"] = inputs.appleSilicon && inputs.macOSMajor >= 15 ? "metal" : "vulkan"
        }

        // An earlier run's sizes are dropped (the restart keeps the environment).
        if env["BB_AUTO_RENDER_RES"] == "1" {
            env["BB_RENDER_RES"] = nil
            env["BB_OUTPUT_RES"] = nil
            env["BB_AUTO_RENDER_RES"] = nil
        }
        let fps = value("BB_FPS", "uncap")
        // Outputs other than 1080p render the whole game at the preset's size.
        if !has("BB_RENDER_RES"), let scaled = inputs.scaled, !scaled.output.isEmpty,
           value("BB_LIVE_RES", "0") != "1" {
            env["BB_RENDER_RES"] = scaled.render
            env["BB_OUTPUT_RES"] = scaled.output
            env["BB_AUTO_RENDER_RES"] = "1"
            env["BB_DMEM_MB"] = value("BB_DMEM_MB", "9152")
        }

        // Pipeline steps.
        var steps = [
            Step(script: "prepare.py", arguments: [game, "--out", out]),
            Step(script: "link_modules.py", arguments: [game, "--out", out]),
            Step(script: "content_profile.py", arguments: [game, "--out", out, "--sku", value("BB_CONTENT_SKU", "full")]),
        ]
        steps.append(Step(script: "patches.py", arguments: [
            "--out", out, "--fps", fps, "--extra", env["BB_PATCHES"] ?? "", "--settings", ini,
            "--game-dir", app0, "--render-res", env["BB_RENDER_RES"] ?? "", "--output-res", env["BB_OUTPUT_RES"] ?? "",
            "--patches-dir", value("BB_PATCHES_DIR", dirs.patchesDir.path),
            "--patches-config", value("BB_PATCHES_CONFIG", dirs.patchesConfig.path),
        ]))

        // Memory model, MoltenVK and Rosetta settings.
        env["BB_PC_MODEL"] = "1"
        env["BB_GUEST_IN_PLACE"] = value("BB_GUEST_IN_PLACE", "1")
        env["BB_LAYER_MEMORY"] = "1"
        env["BB_GUEST_MEMORY"] = "host"
        env["BB_PREUPLOAD"] = value("BB_PREUPLOAD", "1")
        env["BB_UFFD"] = "0"
        env["BB_COPY_GPU_BUFFERS"] = value("BB_COPY_GPU_BUFFERS", "1")
        env["BB_GPU_WRITE_TWINS"] = value("BB_GPU_WRITE_TWINS", "1")
        env["BB_GPU_WRITE_TWINS_MAX"] = value("BB_GPU_WRITE_TWINS_MAX", "65536")
        if !has("BB_VBLANK_HZ") {
            switch fps {
            case "uncap": env["BB_VBLANK_HZ"] = "480"
            case "90": env["BB_VBLANK_HZ"] = "90"
            default: env["BB_VBLANK_HZ"] = "60"
            }
        }
        env["MVK_CONFIG_LOG_LEVEL"] = value("MVK_CONFIG_LOG_LEVEL", "1")
        env["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] = value("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0")
        env["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = value("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0")
        env["BB_GPU_LABELS"] = value("BB_GPU_LABELS", "0")
        env["ROSETTA_ADVERTISE_AVX"] = value("ROSETTA_ADVERTISE_AVX", "1")

        let probe = value("BB_PROBE", inputs.runtime.probe.path)
        let arguments = [out + "/boot-linked.bin", "--content-profile", out + "/content.bin",
                         "--patches", out + "/patches.bin", "--app0", app0, "--user", user,
                         "--timeout", value("BB_TIMEOUT", "0")]

        return LaunchSpec(steps: steps, executable: URL(fileURLWithPath: probe), arguments: arguments,
                          environment: env, workingDirectory: dirs.runDir)
    }
}
