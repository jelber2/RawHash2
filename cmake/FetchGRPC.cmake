# FetchGRPC.cmake
# Find or fetch gRPC and Protobuf for MinKNOW live streaming support.
#
# This module:
#   1. Tries to find system-installed gRPC and Protobuf via find_package
#   2. Falls back to FetchContent if not found
#   3. Provides a function generate_grpc_cpp() to compile .proto files
#
# After inclusion, the following targets are available:
#   gRPC::grpc++           - gRPC C++ library
#   protobuf::libprotobuf  - Protocol Buffers library

include(FetchContent)

# --- Try system-installed gRPC first ---
find_package(Protobuf CONFIG QUIET)
find_package(gRPC CONFIG QUIET)

if(gRPC_FOUND AND Protobuf_FOUND)
    message(STATUS "Found system gRPC: ${gRPC_VERSION}")
    message(STATUS "Found system Protobuf: ${Protobuf_VERSION}")

    # Locate the protoc and grpc_cpp_plugin executables
    if(TARGET protobuf::protoc)
        get_target_property(_PROTOC_EXECUTABLE protobuf::protoc IMPORTED_LOCATION)
        if(NOT _PROTOC_EXECUTABLE)
            get_target_property(_PROTOC_EXECUTABLE protobuf::protoc IMPORTED_LOCATION_RELEASE)
        endif()
    else()
        find_program(_PROTOC_EXECUTABLE protoc)
    endif()

    if(TARGET gRPC::grpc_cpp_plugin)
        get_target_property(_GRPC_CPP_PLUGIN gRPC::grpc_cpp_plugin IMPORTED_LOCATION)
        if(NOT _GRPC_CPP_PLUGIN)
            get_target_property(_GRPC_CPP_PLUGIN gRPC::grpc_cpp_plugin IMPORTED_LOCATION_RELEASE)
        endif()
    else()
        find_program(_GRPC_CPP_PLUGIN grpc_cpp_plugin)
    endif()

else()
    message(STATUS "System gRPC/Protobuf not found, will build from source via FetchContent")
    message(STATUS "This may take several minutes on first build...")

    # Build options to minimize gRPC build size/time
    set(gRPC_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_CSHARP_EXT OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_CSHARP_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_NODE_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_OBJECTIVE_C_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_PHP_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_PYTHON_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_BUILD_GRPC_RUBY_PLUGIN OFF CACHE BOOL "" FORCE)
    set(gRPC_INSTALL OFF CACHE BOOL "" FORCE)
    set(ABSL_PROPAGATE_CXX_STD ON CACHE BOOL "" FORCE)
    set(protobuf_BUILD_TESTS OFF CACHE BOOL "" FORCE)

    FetchContent_Declare(
        grpc
        GIT_REPOSITORY https://github.com/grpc/grpc
        GIT_TAG        v1.60.0
        GIT_SHALLOW    TRUE
        GIT_SUBMODULES_RECURSE TRUE
    )
    FetchContent_MakeAvailable(grpc)

    # After FetchContent, the targets are built as part of the project
    set(_PROTOC_EXECUTABLE $<TARGET_FILE:protobuf::protoc>)
    set(_GRPC_CPP_PLUGIN $<TARGET_FILE:grpc_cpp_plugin>)
endif()

# Verify we have the required executables
if(NOT _PROTOC_EXECUTABLE)
    message(FATAL_ERROR "Could not find protoc executable")
endif()
if(NOT _GRPC_CPP_PLUGIN)
    message(FATAL_ERROR "Could not find grpc_cpp_plugin executable")
endif()

message(STATUS "protoc: ${_PROTOC_EXECUTABLE}")
message(STATUS "grpc_cpp_plugin: ${_GRPC_CPP_PLUGIN}")

# --- Proto code generation function ---
# Usage:
#   generate_grpc_cpp(
#       PROTO_FILES proto/minknow_api/data.proto proto/minknow_api/device.proto ...
#       PROTO_PATH  proto
#       OUTPUT_DIR  ${CMAKE_BINARY_DIR}/generated
#   )
#
# After calling, GRPC_GENERATED_SOURCES is set in the parent scope with the
# list of generated .pb.cc and .grpc.pb.cc files.
function(generate_grpc_cpp)
    cmake_parse_arguments(GEN "" "PROTO_PATH;OUTPUT_DIR" "PROTO_FILES" ${ARGN})

    if(NOT GEN_PROTO_PATH)
        message(FATAL_ERROR "generate_grpc_cpp: PROTO_PATH is required")
    endif()
    if(NOT GEN_OUTPUT_DIR)
        message(FATAL_ERROR "generate_grpc_cpp: OUTPUT_DIR is required")
    endif()
    if(NOT GEN_PROTO_FILES)
        message(FATAL_ERROR "generate_grpc_cpp: PROTO_FILES is required")
    endif()

    set(_all_generated "")

    foreach(_proto ${GEN_PROTO_FILES})
        # Get the relative path (e.g., minknow_api/data.proto)
        file(RELATIVE_PATH _rel_proto "${GEN_PROTO_PATH}" "${_proto}")
        # Get the directory portion (e.g., minknow_api)
        get_filename_component(_rel_dir "${_rel_proto}" DIRECTORY)
        # Get the name without extension (e.g., data)
        get_filename_component(_basename "${_proto}" NAME_WE)

        set(_out_dir "${GEN_OUTPUT_DIR}/${_rel_dir}")

        # Output files
        set(_pb_h   "${_out_dir}/${_basename}.pb.h")
        set(_pb_cc  "${_out_dir}/${_basename}.pb.cc")
        set(_grpc_h "${_out_dir}/${_basename}.grpc.pb.h")
        set(_grpc_cc "${_out_dir}/${_basename}.grpc.pb.cc")

        # Create output directory
        file(MAKE_DIRECTORY "${_out_dir}")

        # Custom command to generate protobuf + grpc stubs
        add_custom_command(
            OUTPUT "${_pb_h}" "${_pb_cc}" "${_grpc_h}" "${_grpc_cc}"
            COMMAND ${_PROTOC_EXECUTABLE}
                --proto_path=${GEN_PROTO_PATH}
                --cpp_out=${GEN_OUTPUT_DIR}
                --grpc_out=${GEN_OUTPUT_DIR}
                --plugin=protoc-gen-grpc=${_GRPC_CPP_PLUGIN}
                "${_proto}"
            DEPENDS "${_proto}"
            COMMENT "Generating gRPC C++ stubs for ${_rel_proto}"
            VERBATIM
        )

        list(APPEND _all_generated "${_pb_cc}" "${_grpc_cc}")
    endforeach()

    # Export the list of generated source files to the parent scope
    set(GRPC_GENERATED_SOURCES ${_all_generated} PARENT_SCOPE)
endfunction()
