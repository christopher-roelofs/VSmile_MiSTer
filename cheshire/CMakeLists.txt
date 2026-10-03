cmake_minimum_required(VERSION 3.20)
project(Cheshire VERSION 0.1.0 LANGUAGES CXX)

option(CHESHIRE_BUILD_SDL "Build the SDL2 frontend" ON)
option(CHESHIRE_BUILD_TESTS "Build core tests" ON)
option(CHESHIRE_FETCH_SDL "Fetch a pinned SDL2 release if no installed package is found" OFF)

add_library(cheshire_core
    src/core/unsp.cpp
    src/core/rom.cpp
    src/core/machine.cpp
    src/core/soc.cpp
    src/core/controller.cpp
    src/core/spu.cpp
    src/core/audio.cpp
    src/core/video.cpp
    src/core/trace.cpp)
target_include_directories(cheshire_core PUBLIC include)
target_compile_features(cheshire_core PUBLIC cxx_std_20)
set_target_properties(cheshire_core PROPERTIES CXX_EXTENSIONS OFF)
if(MSVC)
    target_compile_options(cheshire_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(cheshire_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

# Optional, in-process decompression; no shell commands or POSIX pipes.
find_package(ZLIB QUIET)
if(ZLIB_FOUND)
    target_link_libraries(cheshire_core PRIVATE ZLIB::ZLIB)
    target_compile_definitions(cheshire_core PRIVATE CHESHIRE_HAVE_ZLIB)
endif()

add_executable(cheshire_headless src/headless.cpp src/options.cpp)
target_link_libraries(cheshire_headless PRIVATE cheshire_core)

if(CHESHIRE_BUILD_SDL)
    find_package(SDL2 2.0.18 CONFIG QUIET)
    if(NOT SDL2_FOUND AND CHESHIRE_FETCH_SDL)
        include(FetchContent)
        set(SDL_SHARED OFF CACHE BOOL "" FORCE)
        set(SDL_STATIC ON CACHE BOOL "" FORCE)
        set(SDL_TEST OFF CACHE BOOL "" FORCE)
        FetchContent_Declare(SDL2
            GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
            GIT_TAG 5d249570393f7a37e037abf22cd6012a4cc56a71) # release-2.32.10
        FetchContent_MakeAvailable(SDL2)
    elseif(NOT SDL2_FOUND)
        message(FATAL_ERROR "SDL2 development package not found. Set SDL2_DIR, use -DCHESHIRE_FETCH_SDL=ON, or build headless with -DCHESHIRE_BUILD_SDL=OFF.")
    endif()
    add_executable(cheshire src/frontend/sdl/main.cpp src/options.cpp)
    if(TARGET SDL2::SDL2)
        target_link_libraries(cheshire PRIVATE cheshire_core SDL2::SDL2)
    else()
        target_link_libraries(cheshire PRIVATE cheshire_core SDL2::SDL2-static)
    endif()
    target_compile_definitions(cheshire PRIVATE SDL_MAIN_HANDLED)
    if(WIN32 AND TARGET SDL2::SDL2)
        get_target_property(sdl2_type SDL2::SDL2 TYPE)
        if(sdl2_type STREQUAL "SHARED_LIBRARY")
            add_custom_command(TARGET cheshire POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    $<TARGET_FILE:SDL2::SDL2> $<TARGET_FILE_DIR:cheshire>)
        endif()
    endif()
endif()

if(CHESHIRE_BUILD_TESTS)
    enable_testing()
    add_executable(cheshire_tests tests/core_tests.cpp)
    target_link_libraries(cheshire_tests PRIVATE cheshire_core)
    add_test(NAME core COMMAND cheshire_tests)
    add_test(NAME headless_demo COMMAND cheshire_headless --demo --instructions 10000)
    if(CHESHIRE_BUILD_SDL)
        add_test(NAME sdl_demo COMMAND cheshire --demo --renderer software --frames 3)
        set_tests_properties(sdl_demo PROPERTIES ENVIRONMENT "SDL_VIDEODRIVER=dummy")
    endif()
endif()
