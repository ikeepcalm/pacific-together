set(TARGET PacificTogetherNative)

add_library(${TARGET} SHARED dllmain.cpp trace.cpp net.cpp guard.cpp transport.cpp steam.cpp mute.cpp blackbox.cpp msg.cpp background.cpp find.cpp damage.cpp music.cpp)
target_include_directories(${TARGET} PRIVATE .)
target_link_libraries(${TARGET} PUBLIC UE4SS)

# UE4SS loads Mods/<mod>/dlls/main.dll; own mod folder so RestartMod("PacificTogether") reloads only the Lua mod
add_custom_command(TARGET ${TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_SOURCE_DIR}/../mod/PacificTogetherNative/dlls"
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:${TARGET}> "${CMAKE_SOURCE_DIR}/../mod/PacificTogetherNative/dlls/main.dll"
)
