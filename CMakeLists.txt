cmake_minimum_required(VERSION 4.1)
project(crack_head)

set(CMAKE_CXX_STANDARD 23)
include(FetchContent)

FetchContent_Declare(
        mujoco
        GIT_REPOSITORY https://github.com/google-deepmind/mujoco.git
        GIT_TAG        3.6.0
)

FetchContent_MakeAvailable(mujoco)
add_executable(crack_head main.cpp)

target_link_libraries(crack_head PRIVATE mujoco::mujoco glfw)

file(COPY "${CMAKE_CURRENT_SOURCE_DIR}/hello.xml"
        DESTINATION "${CMAKE_BINARY_DIR}")