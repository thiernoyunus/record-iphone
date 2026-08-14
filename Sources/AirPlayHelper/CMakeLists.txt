cmake_minimum_required(VERSION 3.13)
project(airplay-helper C)

set(CMAKE_C_STANDARD 99)
set(UXPLAY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../Vendor/UxPlay")
if(NOT EXISTS "${UXPLAY_ROOT}/lib/raop.h")
  message(FATAL_ERROR "UxPlay sources missing at ${UXPLAY_ROOT}. Run build.sh to clone them.")
endif()

add_definitions(-DUXPLAY_HAVE_APPLE_P2P -DNOHOLD)

add_subdirectory("${UXPLAY_ROOT}/lib/playfair" "${CMAKE_BINARY_DIR}/playfair")
add_subdirectory("${UXPLAY_ROOT}/lib/llhttp" "${CMAKE_BINARY_DIR}/llhttp")
add_subdirectory("${UXPLAY_ROOT}/lib/dns_sd" "${CMAKE_BINARY_DIR}/dns_sd")
add_subdirectory("${UXPLAY_ROOT}/lib" "${CMAKE_BINARY_DIR}/airplay")

add_executable(airplay-helper main.c)
target_include_directories(airplay-helper PRIVATE "${UXPLAY_ROOT}/lib")
target_link_libraries(airplay-helper PRIVATE airplay)
