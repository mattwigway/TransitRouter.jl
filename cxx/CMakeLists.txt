# copied and minimally modified from osrm-backend example,
# Copyright (c) 2017, Project OSRM contributors
cmake_minimum_required(VERSION 3.19.0)

if(CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_CURRENT_BINARY_DIR AND NOT MSVC_IDE)
  message(FATAL_ERROR "In-source builds are not allowed.
Please create a directory and run cmake from there, passing the path to this source directory as the last argument.
This process created the file `CMakeCache.txt' and the directory `CMakeFiles'. Please delete them.")
endif()

if(NOT CMAKE_BUILD_TYPE MATCHES Debug)
  set(CMAKE_BUILD_TYPE Release)
endif()

project(osrmjl)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

set(bitness 32)
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(bitness 64)
  message(STATUS "Building on a 64 bit system")
else()
  message(STATUS "Building on a 32 bit system")
endif()

if(WIN32 AND MSVC_VERSION LESS 1900)
  message(FATAL_ERROR "Building with Microsoft compiler needs Latest Visual Studio 2015 (Community or better)")
endif()

find_package(LibOSRM REQUIRED)
find_package(Boost REQUIRED COMPONENTS regex date_time chrono filesystem iostreams thread system)

link_directories(${LibOSRM_LIBRARY_DIRS} ${Boost_LIBRARY_DIRS})
add_library(osrmjl SHARED osrmjl.cpp)

target_link_libraries(osrmjl PRIVATE ${LibOSRM_LIBRARIES} ${LibOSRM_DEPENDENT_LIBRARIES} ${Boost_LIBRARIES})
include_directories(SYSTEM ${LibOSRM_INCLUDE_DIRS} ${Boost_INCLUDE_DIRS})
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${LibOSRM_CXXFLAGS} ${Boost_CXXFLAGS}")