cmake_minimum_required(VERSION 3.14)
project(onyx_updater LANGUAGES CXX)

# Programme de mise a jour Windows (ADR-0030). Installe a cote de app.exe par
# le CMakeLists.txt parent : il part donc dans l'installeur Inno comme dans le
# ZIP portable sans rien declarer ailleurs.

add_executable(onyx-updater WIN32
  "main.cpp"
  "package.cpp"
  "service.cpp"
  "splash.cpp"
  "updater.rc"
  "onyx-updater.exe.manifest"
)

apply_standard_settings(onyx-updater)
# Les textes de la fenetre sont en francais dans le source : sans /utf-8, MSVC
# lit un fichier sans BOM en cp1252 et « à » devient « Ã  ».
target_compile_options(onyx-updater PRIVATE /utf-8)

target_compile_definitions(onyx-updater PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(onyx-updater PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(onyx-updater PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(onyx-updater PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(onyx-updater PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")
target_compile_definitions(onyx-updater PRIVATE "NOMINMAX")

target_link_libraries(onyx-updater PRIVATE "bcrypt.lib" "version.lib" "dwmapi.lib")
