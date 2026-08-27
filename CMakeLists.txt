cmake_minimum_required(VERSION 3.16)
project(BiliQt_QuickVulkan VERSION 1.0.0 LANGUAGES CXX C)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# ===== 编译优化 =====
set(CMAKE_UNITY_BUILD ON)
if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    set(CMAKE_UNITY_BUILD_BATCH_SIZE 16)
else()
    set(CMAKE_UNITY_BUILD_BATCH_SIZE 4)
endif()

# MinGW 在 Unity Build 下生成的目标文件可能超过默认 section 限制，需要 big-obj 格式
if(MINGW)
    add_compile_options(-Wa,-mbig-obj)
endif()

find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
endif()

find_package(Qt6 REQUIRED COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    Network
    Multimedia
    WebSockets
    ShaderTools
    Svg
    OpenGL
)

find_package(Qt6 REQUIRED COMPONENTS
    QuickEffects
)

find_package(Qt6 COMPONENTS
    Core5Compat
    Quick5Compat
    QUIET
)

if(Qt6Quick5Compat_FOUND)
    message(STATUS "Qt5Compat found, FluWindow acrylic effect enabled")
else()
    message(STATUS "Qt5Compat not found, FluWindow acrylic effect disabled")
endif()

set(QT_VERSION_MAJOR 6)
if(WIN32)
    message(STATUS "Using Qt6 with Qt Quick + D3D11 (MPV DXGI)")
else()
    message(STATUS "Using Qt6 with Qt Quick + OpenGL")
endif()

set(FLUENTUI_QML_PATH "/usr/lib/qml/FluentUI" CACHE PATH "Path to FluentUI QML plugin")
if(EXISTS ${FLUENTUI_QML_PATH})
    message(STATUS "FluentUI found at: ${FLUENTUI_QML_PATH}")
    list(APPEND QML_IMPORT_PATH ${FLUENTUI_QML_PATH})
else()
    message(WARNING "FluentUI not found, please compile and install FluentUI first")
endif()

# Vulkan 仅在 Windows 查找：HAS_VULKAN 当前源码未引用（死定义），
# 且 macOS 上会误链 Homebrew 的 MoltenVK loader——目标机没有该库时
# .app 会因缺 dylib 拒绝启动
if(WIN32)
    find_package(Vulkan QUIET)
    if(Vulkan_FOUND)
        message(STATUS "Vulkan found: ${Vulkan_LIBRARIES}")
        add_compile_definitions(HAS_VULKAN=1)
    else()
        message(WARNING "Vulkan not found, will fall back to OpenGL backend")
    endif()
endif()

set(PROJECT_SOURCES
    src/main.cpp
    src/core/AppManager.cpp
    src/core/AppSettings.cpp
    src/core/CircularReveal.cpp
    src/api/ApiManager.cpp
    src/api/PlayUrlManager.cpp
    src/api/SponsorBlockManager.cpp
    src/user/LoginManager.cpp
    src/user/QRCodeGenerator.cpp
    src/util/WbiSigner.cpp
    src/interaction/CommentManager.cpp
    src/interaction/InteractionManager.cpp
    src/player/MediaDownloader.cpp
    src/danmaku/DanmakuManager.cpp
    src/danmaku/DanmakuSettings.cpp
    src/danmaku/LiveDanmakuManager.cpp
    src/danmaku/VideoDanmakuManager.cpp
    src/danmaku/EmoticonCache.cpp
    src/player/DanmakuCanvas.cpp
    src/player/FramePacer.cpp
    res/res.qrc
)

# Windows 使用 D3D11 RHI + MPV DXGI render context；非 Windows 使用 OpenGL
if(WIN32)
    list(APPEND PROJECT_SOURCES src/player/MpvObjectD3D11.cpp)
else()
    list(APPEND PROJECT_SOURCES src/player/MpvObject.cpp)
endif()

if(WIN32)
    set(APP_ICON_PATH "${CMAKE_SOURCE_DIR}/res/app.ico")
    configure_file(res/app.rc.in ${CMAKE_BINARY_DIR}/res/app.rc)
    list(APPEND PROJECT_SOURCES ${CMAKE_BINARY_DIR}/res/app.rc)
endif()

set(PROJECT_HEADERS
    src/core/AppManager.h
    src/core/AppSettings.h
    src/core/CircularReveal.h
    src/api/ApiManager.h
    src/api/PlayUrlManager.h
    src/api/SponsorBlockManager.h
    src/user/LoginManager.h
    src/user/QRCodeGenerator.h
    src/util/WbiSigner.h
    src/interaction/CommentManager.h
    src/interaction/InteractionManager.h
    src/player/MediaDownloader.h
    src/danmaku/DanmakuManager.h
    src/danmaku/DanmakuSettings.h
    src/danmaku/LiveDanmakuManager.h
    src/danmaku/VideoDanmakuManager.h
    src/danmaku/EmoticonCache.h
    src/player/DanmakuCanvas.h
    src/player/FramePacer.h
)

if(WIN32)
    list(APPEND PROJECT_HEADERS src/player/MpvObjectD3D11.h)
else()
    list(APPEND PROJECT_HEADERS src/player/MpvObject.h)
endif()

set(ICONPARK_FONT "qml/assets/iconpark.ttf")
if(NOT EXISTS "${CMAKE_SOURCE_DIR}/${ICONPARK_FONT}")
    message(FATAL_ERROR
        "未找到 IconPark 图标字体文件：${ICONPARK_FONT}\n"
        "请运行生成脚本：fontforge -script scripts/build_iconpark_font.py")
endif()

# ===== QML 资源文件列表定义（在 target 创建后用 qt_add_resources 添加）=====
file(GLOB _ICONPARK_SVG_ABS "${CMAKE_SOURCE_DIR}/qml/assets/icons/iconpark/*.svg")
set(ICONPARK_SVG "")
foreach(_s IN LISTS _ICONPARK_SVG_ABS)
    file(RELATIVE_PATH _r "${CMAKE_SOURCE_DIR}" "${_s}")
    list(APPEND ICONPARK_SVG "${_r}")
endforeach()

set(QML_RESOURCE_FILES
    qml/main.qml
    qml/GlobalState.qml
    qml/pages/HomePage.qml
    qml/pages/RecommendPage.qml
    qml/pages/HotPage.qml
    qml/pages/LivePage.qml
    qml/pages/LiveRecommendPage.qml
    qml/pages/LiveFollowingPage.qml
    qml/pages/LivePlayerPage.qml
    qml/pages/SearchPage.qml
    qml/pages/VideoPlayerPage.qml
    qml/pages/DynamicPage.qml
    qml/pages/HistoryPage.qml
    qml/pages/UserProfilePage.qml
    qml/components/NavigationBar.qml
    qml/components/VideoCard.qml
    qml/components/LiveCard.qml
    qml/components/HistoryCard.qml
    qml/components/UserCard.qml
    qml/components/IconParkIcon.qml
    qml/components/IconFontIcon.qml
    qml/components/LoginPopup.qml
    qml/components/DanmakuOverlay.qml
    qml/components/CircleAvatar.qml
    qml/components/FluPaginationNoArrow.qml
    qml/components/FluPaginationSimple.qml
    qml/components/CommentPanel.qml
    qml/components/CommentCardBg.qml
    qml/components/AvatarWithPendant.qml
    qml/components/SegmentedDigits.qml
    qml/components/ImageViewer.qml
    qml/styles/Theme.qml
    qml/assets/icons/play.png
    qml/assets/iconpark.ttf
)

include_directories(
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/core
    ${CMAKE_SOURCE_DIR}/src/api
    ${CMAKE_SOURCE_DIR}/src/player
    ${CMAKE_SOURCE_DIR}/src/danmaku
    ${CMAKE_SOURCE_DIR}/src/user
    ${CMAKE_SOURCE_DIR}/src/user/qrencode
    ${CMAKE_SOURCE_DIR}/src/interaction
    ${CMAKE_SOURCE_DIR}/src/models
    ${CMAKE_SOURCE_DIR}/src/util
)

set(QRENCODE_SOURCES
    src/user/qrencode/bitstream.c
    src/user/qrencode/mask.c
    src/user/qrencode/mmask.c
    src/user/qrencode/mqrspec.c
    src/user/qrencode/qrencode.c
    src/user/qrencode/qrinput.c
    src/user/qrencode/qrspec.c
    src/user/qrencode/rsecc.c
    src/user/qrencode/split.c
)
add_library(qrencode STATIC ${QRENCODE_SOURCES})
target_include_directories(qrencode PUBLIC ${CMAKE_SOURCE_DIR}/src/user/qrencode)
set_target_properties(qrencode PROPERTIES UNITY_BUILD OFF)

qt_add_executable(${PROJECT_NAME}
    ${PROJECT_SOURCES}
    ${PROJECT_HEADERS}
)

# DanmakuCanvas.cpp 包含 <windows.h>（DWM vsync 查询），为避免宏污染同批次
# 的其他翻译单元，不参与 unity build 合并
# （注意属性名必须是 SKIP_UNITY_BUILD_INCLUSION，此前误写为
#   SKIP_UNITY_BUILD_IN 是不存在的属性，排除从未生效）
if(WIN32)
    set_source_files_properties(src/player/DanmakuCanvas.cpp PROPERTIES SKIP_UNITY_BUILD_INCLUSION ON)
    # FramePacer.cpp 同样包含 <windows.h>（DWM vsync 网格查询），同批隔离
    set_source_files_properties(src/player/FramePacer.cpp PROPERTIES SKIP_UNITY_BUILD_INCLUSION ON)
endif()

# 编译后的可执行文件名称
set_target_properties(${PROJECT_NAME} PROPERTIES OUTPUT_NAME "BbQ")

# macOS：生成 .app bundle（MACOSX_BUNDLE_GUI_IDENTIFIER 决定 bundle id；
# BUNDLE 前缀让 install 产物为 BbQ.app，供 CI 直接打包 artifact）
if(APPLE)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_BUNDLE_NAME "BbQ"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.bbq.biliqt"
        MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
        MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
    )
endif()

# 用 qt_add_resources 手动添加 QML 资源，确保资源路径为 qrc:/BiliQt/qml/...
qt_add_resources(${PROJECT_NAME} "app_qml"
    PREFIX "/BiliQt"
    FILES
        ${QML_RESOURCE_FILES}
        ${ICONPARK_SVG}
)

set_source_files_properties(qml/GlobalState.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

set_source_files_properties(qml/styles/Theme.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(${PROJECT_NAME}
    URI BiliQt
    VERSION 1.0
    QML_FILES
        qml/main.qml
        qml/GlobalState.qml
        qml/pages/HomePage.qml
        qml/pages/RecommendPage.qml
        qml/pages/HotPage.qml
        qml/pages/LivePage.qml
        qml/pages/LiveRecommendPage.qml
        qml/pages/LiveFollowingPage.qml
        qml/pages/LivePlayerPage.qml
        qml/pages/SearchPage.qml
        qml/pages/VideoPlayerPage.qml
        qml/pages/DynamicPage.qml
        qml/pages/HistoryPage.qml
        qml/pages/UserProfilePage.qml
        qml/components/NavigationBar.qml
        qml/components/VideoCard.qml
        qml/components/LiveCard.qml
        qml/components/HistoryCard.qml
        qml/components/UserCard.qml
        qml/components/IconParkIcon.qml
        qml/components/IconFontIcon.qml
        qml/components/LoginPopup.qml
        qml/components/DanmakuOverlay.qml
        qml/components/CircleAvatar.qml
        qml/components/FluPaginationNoArrow.qml
        qml/components/FluPaginationSimple.qml
        qml/components/CommentPanel.qml
        qml/components/CommentCardBg.qml
        qml/components/AvatarWithPendant.qml
        qml/components/SegmentedDigits.qml
        qml/components/ImageViewer.qml
        qml/styles/Theme.qml
    RESOURCES
        qml/assets/icons/play.png
        qml/assets/iconpark.ttf
        res/app.ico
)

# qmlcachegen 生成的 QML 缓存代码（*_qml.cpp）符号名极长（AOT 函数修饰名
# 内嵌 QML 文件路径），MinGW as 的 COFF 字符串表有上限：带 -g 的配置
# （Debug/RelWithDebInfo）下并入 unity 批次会 "string table overflow"，
# Debug 全量编译必现。排除出 unity 独立编译，并降为 -g1 行号级调试信息
# （生成的 AOT 代码无需完整调试信息；gcc 对 -g 档位后出现者生效）。
# Release 无 -g 不受影响，无需排除以保留其 unity 加速
if(NOT CMAKE_BUILD_TYPE STREQUAL "Release")
    get_target_property(_qmlcache_srcs ${PROJECT_NAME} SOURCES)
    foreach(_src IN LISTS _qmlcache_srcs)
        if(_src MATCHES "_qml\\.cpp$")
            set_source_files_properties(${_src} PROPERTIES
                SKIP_UNITY_BUILD_INCLUSION ON
                COMPILE_OPTIONS "$<$<CONFIG:Debug>:-g1>")
        endif()
    endforeach()
endif()

target_precompile_headers(${PROJECT_NAME} PRIVATE
    <string>
    <vector>
    <list>
    <map>
    <memory>
    <functional>
    <algorithm>
    <iostream>
)

target_link_libraries(${PROJECT_NAME} PRIVATE
    Qt${QT_VERSION_MAJOR}::Core
    Qt${QT_VERSION_MAJOR}::Gui
    Qt${QT_VERSION_MAJOR}::Qml
    Qt${QT_VERSION_MAJOR}::Quick
    Qt${QT_VERSION_MAJOR}::QuickEffects
    Qt${QT_VERSION_MAJOR}::QuickControls2
    Qt${QT_VERSION_MAJOR}::Network
    Qt${QT_VERSION_MAJOR}::Multimedia
    Qt${QT_VERSION_MAJOR}::Svg
    Qt${QT_VERSION_MAJOR}::WebSockets
    Qt${QT_VERSION_MAJOR}::OpenGL
    qrencode
)

# z：zlib 压缩（直播弹幕包 inflate 解压等）。macOS 系统提供 /usr/lib/libz.dylib，
# 直接调用 zlib API 时仍需显式链接（-lz）
target_link_libraries(${PROJECT_NAME} PRIVATE z)

# DanmakuCanvas 图集路径使用 QRhi private API（newTexture/uploadTexture），
# RHI 接口跨后端通用（D3D11/Metal/OpenGL），private 头随标准 Qt 安装提供
target_link_libraries(${PROJECT_NAME} PRIVATE Qt${QT_VERSION_MAJOR}::GuiPrivate)

# Windows 专属系统库
# d3d11/dxgi：MpvObjectD3D11 渲染路径
# dwmapi：DanmakuCanvas 的 vsync 网格查询（DwmGetCompositionTimingInfo）
if(WIN32)
    target_link_libraries(${PROJECT_NAME} PRIVATE
        d3d11
        dxgi
        dwmapi
    )

    # 崩溃转储所需的系统库：dbghelp / psapi
    # MinGW 下可能以 libdbghelp 形式提供，或不存在（main.cpp 已做动态加载兜底）
    find_library(DBGHELP_LIB dbghelp libdbghelp)
    if(DBGHELP_LIB)
        target_link_libraries(${PROJECT_NAME} PRIVATE ${DBGHELP_LIB})
    endif()
    find_library(PSAPI_LIB psapi)
    if(PSAPI_LIB)
        target_link_libraries(${PROJECT_NAME} PRIVATE ${PSAPI_LIB})
    endif()
endif()

# Release 模式下关闭 qDebug / qInfo 输出，仅保留 qWarning / qCritical
target_compile_definitions(${PROJECT_NAME} PRIVATE
    $<$<CONFIG:Release>:QT_NO_DEBUG_OUTPUT>
    $<$<CONFIG:Release>:QT_NO_INFO_OUTPUT>
)

if(Vulkan_FOUND)
    target_link_libraries(${PROJECT_NAME} PRIVATE Vulkan::Vulkan)
endif()

if(WIN32)
    if(DEFINED ENV{MPV_DIR})
        set(MPV_DIR $ENV{MPV_DIR} CACHE PATH "mpv directory from environment variable")
    elseif(NOT DEFINED MPV_DIR)
        set(MPV_DIR "" CACHE PATH "Path to mpv-dev directory")
    endif()

    if(MPV_DIR AND EXISTS ${MPV_DIR})
        include_directories(${MPV_DIR}/include ${MPV_DIR}/include/mpv)
        target_link_directories(${PROJECT_NAME} PRIVATE ${MPV_DIR}/lib)
        target_link_libraries(${PROJECT_NAME} PRIVATE mpv-2)
    else()
        message(WARNING "libmpv not found, video player will be disabled")
        add_compile_definitions(NO_MPV=1)
    endif()

    set_target_properties(${PROJECT_NAME} PROPERTIES WIN32_EXECUTABLE TRUE)
elseif(UNIX)
    # Homebrew（Apple Silicon 装在 /opt/homebrew，Intel 在 /usr/local）
    # 与 Linux 系统路径一并作为候选
    find_library(MPV_LIBRARY mpv
        HINTS /opt/homebrew/lib /usr/local/lib /usr/lib)
    find_path(MPV_INCLUDE_DIR mpv/client.h
        HINTS /opt/homebrew/include /usr/local/include
        PATHS /usr/include)
    if(MPV_LIBRARY AND MPV_INCLUDE_DIR)
        target_include_directories(${PROJECT_NAME} PRIVATE ${MPV_INCLUDE_DIR})
        target_link_libraries(${PROJECT_NAME} PRIVATE ${MPV_LIBRARY})
    else()
        message(WARNING "libmpv not found, video player will be disabled")
        add_compile_definitions(NO_MPV=1)
    endif()
endif()

install(TARGETS ${PROJECT_NAME}
    BUNDLE DESTINATION .
    RUNTIME DESTINATION bin
)

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_custom_command(TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/qml
            $<TARGET_FILE_DIR:${PROJECT_NAME}>/qml
        COMMENT "Copying QML files to output directory for hot reload..."
    )
endif()