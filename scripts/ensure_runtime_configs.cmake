# 构建后补齐"客户端文件夹里的开关文件"
#
# BbQ 有一部分功能是靠 **exe 同目录的文件** 开启的，缺文件时功能静默关闭：
#   · bsb.conf            空降助手（BilibiliSponsorBlock）接口基地址
#   · mpv-config/mpv.conf  mpv 选项（Windows 下 mpv 的 config-dir 就指向这里）
# 新机器/新克隆很容易漏掉，表现为"功能莫名其妙没有"，所以构建后自动补一份。
#
# 做法：仓库里 `config/` 放模板，输出目录缺文件时从模板复制。
#
# **只创建、不覆盖**。这两个文件在运行期是要被手改的：
#   · mpv.conf：Intel 机器写 `vf=` 关掉补帧，AMD 机器删掉这行启用 amf_frc
#   · bsb.conf：可以换成自建接口
# 每次构建都覆盖等于把用户的调整清掉，所以已存在就原样跳过。
#
# 调用方式（见 CMakeLists.txt）：
#   cmake -DOUT_DIR=<exe 目录> -DSRC_DIR=<源码根> -P scripts/ensure_runtime_configs.cmake

if(NOT DEFINED OUT_DIR OR OUT_DIR STREQUAL "")
    message(FATAL_ERROR "ensure_runtime_configs: 缺少 OUT_DIR")
endif()
if(NOT DEFINED SRC_DIR OR SRC_DIR STREQUAL "")
    message(WARNING "ensure_runtime_configs: 缺少 SRC_DIR，将只写内置默认值（不读模板）")
endif()

# ---------- bsb.conf：exe 同目录，首个有效行 = 接口基地址 ----------
if(EXISTS "${OUT_DIR}/bsb.conf")
    message(STATUS "ensure_runtime_configs: bsb.conf 已存在，保持不动")
elseif(EXISTS "${SRC_DIR}/config/bsb.conf")
    file(COPY "${SRC_DIR}/config/bsb.conf" DESTINATION "${OUT_DIR}")
    message(STATUS "ensure_runtime_configs: 已从 config/bsb.conf 复制")
else()
    file(WRITE "${OUT_DIR}/bsb.conf" "https://www.bsbsb.top/\n")
    message(STATUS "ensure_runtime_configs: 模板缺失，已写入内置默认 bsb.conf")
endif()

# ---------- mpv-config/mpv.conf ----------
set(_mpvdir "${OUT_DIR}/mpv-config")
file(MAKE_DIRECTORY "${_mpvdir}")
if(EXISTS "${_mpvdir}/mpv.conf")
    message(STATUS "ensure_runtime_configs: mpv-config/mpv.conf 已存在，保持不动")
elseif(EXISTS "${SRC_DIR}/config/mpv.conf")
    file(COPY "${SRC_DIR}/config/mpv.conf" DESTINATION "${_mpvdir}")
    message(STATUS "ensure_runtime_configs: 已从 config/mpv.conf 复制")
else()
    # 兜底：连模板都没有时至少给一份能跑的配置，别让 mpv 读空文件
    # hr-seek=no 的理由见 config/mpv.conf 注释（default 对向前 seek 仍精确）
    file(WRITE "${_mpvdir}/mpv.conf"
         "vf=\nhr-seek=no\nvideo-sync=display-resample\n")
    message(STATUS "ensure_runtime_configs: 模板缺失，已写入内置默认 mpv.conf")
endif()
