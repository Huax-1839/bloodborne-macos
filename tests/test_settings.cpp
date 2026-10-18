// SPDX-License-Identifier: GPL-2.0-or-later
// bbport_settings.cpp: the menu saves its keys into bbport.ini and keeps the launcher's (controls).
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include "gpu/shim/bbport_settings.h"

static std::string Read(const char* path) {
    std::ifstream file(path);
    std::stringstream text;
    text << file.rdbuf();
    return text.str();
}

int main() {
    char path[] = "/tmp/bbport-settings-test-XXXXXX";
    const int fd = mkstemp(path);
    assert(fd >= 0);
    const char ini[] = "# launcher\nupscaler=fsr3\nkey.cross=X, Space\npad.circle=a\nshow_fps=0\n"
                       "fullscreen_hint=1\n";
    assert(write(fd, ini, sizeof(ini) - 1) == ssize_t(sizeof(ini) - 1));
    close(fd);
    setenv("BB_CONFIG", path, 1);

    BbSettings::Load();
    auto& s = BbSettings::Get();
    assert(s.upscaler == BbSettings::UpscalerFsr3 && !s.show_fps);
    s.show_fps = true;
    s.upscaler = BbSettings::UpscalerTaa;
    BbSettings::Save();

    const std::string saved = Read(path);
    // The launcher's controls, its other keys and comments stay; the menu's keys are replaced
    // in place, new ones appended.
    assert(saved.find("# launcher\nupscaler=taa\nkey.cross=X, Space\npad.circle=a\nshow_fps=1\n"
                      "fullscreen_hint=1\n") == 0);
    assert(saved.find("upscaler=fsr3") == std::string::npos);

    s.show_fps = false;
    s.upscaler = BbSettings::UpscalerFsr3;
    BbSettings::Load();
    assert(s.show_fps && s.upscaler == BbSettings::UpscalerTaa);
    assert(saved.find("fsr4") == std::string::npos);

    // The removed providers' names in older files and BB_UPSCALER use FSR 3.1; their old keys
    // are ignored.
    for (const char* legacy : {"fsr4", "fsr411", "dlss"}) {
        const std::string old = std::string("upscaler=") + legacy +
                                "\nfsr4_auto_exposure=0\nfsr4_invert_jitter=1\n";
        FILE* file = std::fopen(path, "w");
        assert(file);
        std::fputs(old.c_str(), file);
        std::fclose(file);
        s.upscaler = BbSettings::UpscalerOff;
        BbSettings::Load();
        assert(s.upscaler == BbSettings::UpscalerFsr3);
        setenv("BB_UPSCALER", legacy, 1);
        s.upscaler = BbSettings::UpscalerOff;
        BbSettings::Load();
        assert(s.upscaler == BbSettings::UpscalerFsr3);
        unsetenv("BB_UPSCALER");
    }
    unlink(path);
    std::puts("PASS: settings save keeps other keys and reloads");
}
