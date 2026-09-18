cmake_minimum_required(VERSION 3.16)
project(CiScriptSmoke LANGUAGES CXX)

add_executable(ci-script-smoke main.cpp)
install(TARGETS ci-script-smoke RUNTIME DESTINATION bin)
