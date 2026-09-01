/*
 @licstart  The following is the entire license notice for the JavaScript code in this file.

 The MIT License (MIT)

 Copyright (C) 1997-2020 by Dimitri van Heesch

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 and associated documentation files (the "Software"), to deal in the Software without restriction,
 including without limitation the rights to use, copy, modify, merge, publish, distribute,
 sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
 BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

 @licend  The above is the entire license notice for the JavaScript code in this file
*/
var NAVTREE =
[
  [ "libyang", "index.html", [
    [ "About", "index.html", "index" ],
    [ "Building libyang", "build.html", [
      [ "Requirements", "build.html#buildRequirements", [
        [ "Building Requirements", "build.html#buildRequirementsCompile", [
          [ "Optional Requirements", "build.html#buildRequirementsCompileOptional", null ]
        ] ],
        [ "Runtime Requirements", "build.html#buildRequirementsRun", null ]
      ] ],
      [ "Building", "build.html#buildCommands", null ],
      [ "Build Types", "build.html#buildTypes", [
        [ "Release", "build.html#buildTypesRelese", null ],
        [ "Debug", "build.html#buildTypesDebug", null ],
        [ "ABICheck", "build.html#buildTypesABICheck", null ],
        [ "DocOnly", "build.html#buildTypesDocOnly", null ]
      ] ]
    ] ],
    [ "Transition Manual (1.x -> 2.0)", "transition1_2.html", [
      [ "General Changes", "transition1_2.html#transition1_2General", [
        [ "Errors Handling", "transition1_2.html#transition1_2GeneralErros", null ],
        [ "Input / Output Processing", "transition1_2.html#transition1_2GeneralInOut", null ],
        [ "Output Formatting", "transition1_2.html#transition1_2GeneralOutputFormatting", null ],
        [ "Addressing", "transition1_2.html#transition1_2GeneralXPath", null ]
      ] ],
      [ "Context", "transition1_2.html#transition1_2Context", null ],
      [ "YANG Modules (Schema)", "transition1_2.html#transition1_2Schemas", null ],
      [ "Data Instances", "transition1_2.html#transition1_2Data", null ]
    ] ],
    [ "Transition Manual (2.x -> 3.0)", "transition2_3.html", [
      [ "Logging", "transition2_3.html#transition2_3Logging", null ],
      [ "Data Creation", "transition2_3.html#transition2_3New", null ],
      [ "Other Minor Changes", "transition2_3.html#transition2_3Minor", null ]
    ] ],
    [ "libyang API Overview", "howto.html", [
      [ "General notes", "howto.html#howtoGeneral", null ],
      [ "Data Structures", "howto_structures.html", [
        [ "Sized Arrays", "howto_structures.html#sizedarrays", null ],
        [ "Lists", "howto_structures.html#struct_lists", null ]
      ] ],
      [ "Errors Handling", "howto_errors.html", null ],
      [ "Information Logging", "howto_logger.html", null ],
      [ "Threading Limitations", "howto_threads.html", [
        [ "Context", "howto_threads.html#context", null ],
        [ "Data Trees", "howto_threads.html#data", null ]
      ] ],
      [ "Context", "howto_context.html", [
        [ "Errors Handling", "howto_errors.html", null ],
        [ "Context Dictionary", "howto_context_dict.html", [
          [ "Functions List", "howto_context.html#autotoc_md0", [
            [ "Functions List", "howto_context_dict.html#autotoc_md1", null ]
          ] ]
        ] ]
      ] ],
      [ "Input Processing", "howto_input.html", [
        [ "Parsing YANG Modules", "howto_schema_parsers.html", [
          [ "Functions List", "howto_input.html#autotoc_md2", null ],
          [ "libyang Parsers List", "howto_input.html#autotoc_md3", [
            [ "Functions List", "howto_schema_parsers.html#autotoc_md9", null ]
          ] ]
        ] ],
        [ "Parsing Data", "howto_data_parsers.html", [
          [ "Validating Data", "howto_data_validation.html", [
            [ "Functions List", "howto_data_parsers.html#autotoc_md7", [
              [ "Functions List", "howto_data_validation.html#autotoc_md8", null ]
            ] ]
          ] ],
          [ "Default Values", "howto_data_w_d.html", null ]
        ] ]
      ] ],
      [ "Output Processing", "howto_output.html", [
        [ "Module Printers", "howto_schema_printers.html", [
          [ "Functions List", "howto_output.html#autotoc_md5", null ],
          [ "libyang Printers List", "howto_output.html#autotoc_md6", [
            [ "Functions List", "howto_schema_printers.html#autotoc_md11", null ]
          ] ]
        ] ],
        [ "Printing Data", "howto_data_printers.html", null ]
      ] ],
      [ "YANG Modules", "howto_schema.html", [
        [ "Parsing YANG Modules", "howto_schema_parsers.html", [
          [ "Functions List (not assigned to above subsections)", "howto_schema.html#autotoc_md20", [
            [ "Functions List", "howto_schema_parsers.html#autotoc_md9", null ]
          ] ]
        ] ],
        [ "YANG Features", "howto_schema_features.html", null ],
        [ "Plugins", "howto_plugins.html", [
          [ "Type Plugins", "howto_plugins_types.html", null ],
          [ "Extension Plugins", "howto_plugins_extensions.html", null ]
        ] ],
        [ "Module Printers", "howto_schema_printers.html", null ]
      ] ],
      [ "Data Instances", "howto_data.html", [
        [ "Metadata Support", "howto_data.html#howtoDataMetadata", null ],
        [ "yang-data Support", "howto_data.html#howtoDataYangdata", null ],
        [ "mount-point Support", "howto_data.html#howtoDataMountpoint", null ],
        [ "Parsing Data", "howto_data_parsers.html", [
          [ "Functions List (not assigned to above subsections)", "howto_data.html#autotoc_md17", [
            [ "Functions List", "howto_data_parsers.html#autotoc_md7", null ]
          ] ],
          [ "Validating Data", "howto_data_validation.html", null ],
          [ "Default Values", "howto_data_w_d.html", null ]
        ] ],
        [ "Validating Data", "howto_data_validation.html", null ],
        [ "Default Values", "howto_data_w_d.html", null ],
        [ "Manipulating Data", "howto_data_manipulation.html", null ],
        [ "Printing Data", "howto_data_printers.html", null ],
        [ "LYB Binary Format", "howto_data_l_y_b.html", [
          [ "Format of specific data type values", "howto_data_l_y_b.html#howtoDataLYBTypes", [
            [ "binary (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesBinary", null ],
            [ "bits (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesBits", null ],
            [ "boolean (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesBoolean", null ],
            [ "decimal64 (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesDecimal64", null ],
            [ "empty (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesEmpty", null ],
            [ "enumeration (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesEnumeration", null ],
            [ "identityref (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesIdentityref", null ],
            [ "instance-identifier (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesInstanceIdentifier", null ],
            [ "instance-identifier-keys (yang)", "howto_data_l_y_b.html#howtoDataLYBTypesInstanceIdentifierKeys", null ],
            [ "(u)int(8/16/32/64) (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesInteger", null ],
            [ "leafref (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesLeafref", null ],
            [ "string (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesString", null ],
            [ "union (built-in)", "howto_data_l_y_b.html#howtoDataLYBTypesUnion", null ],
            [ "ipv4-address (ietf-inet-types)", "howto_data_l_y_b.html#howtoDataLYBTypesIPv4Address", null ],
            [ "ipv4-address-no-zone (ietf-inet-types)", "howto_data_l_y_b.html#howtoDataLYBTypesIPv4AddressNoZone", null ],
            [ "ipv6-address (ietf-inet-types)", "howto_data_l_y_b.html#howtoDataLYBTypesIPv6Address", null ],
            [ "ipv6-address-no-zone (ietf-inet-types)", "howto_data_l_y_b.html#howtoDataLYBTypesIPv6AddressNoZone", null ],
            [ "ipv4-prefix (ietf-inet-types)", "howto_data_l_y_b.html#howtoDataLYBTypesIPv4Prefix", null ],
            [ "ipv6-prefix (ietf-inet-types)", "howto_data_l_y_b.html#howtoDataLYBTypesIPv6Prefix", null ],
            [ "date-and-time (ietf-yang-types)", "howto_data_l_y_b.html#howtoDataLYBTypesDateAndTime", null ],
            [ "phys-address, mac-address, hex-string, uuid (ietf-yang-types)", "howto_data_l_y_b.html#howtoDataLYBTypesHexString", null ],
            [ "xpath1.0 (ietf-yang-types)", "howto_data_l_y_b.html#howtoDataLYBTypesXpath10", null ],
            [ "node-instance-identifier (ietf-netconf-acm)", "howto_data_l_y_b.html#howtoDataLYBTypesNodeInstanceIdentifier", null ],
            [ "time-period (libnetconf2-netconf-server)", "howto_data_l_y_b.html#howtoDataLYBTypesTimePeriod", null ]
          ] ]
        ] ]
      ] ],
      [ "XPath Addressing", "howto_x_path.html", [
        [ "XPath", "howto_x_path.html#autotoc_md12", [
          [ "Functions List", "howto_x_path.html#autotoc_md13", null ]
        ] ],
        [ "Path", "howto_x_path.html#autotoc_md14", [
          [ "Examples", "howto_x_path.html#autotoc_md15", null ],
          [ "Functions List", "howto_x_path.html#autotoc_md16", null ]
        ] ]
      ] ],
      [ "Plugins", "howto_plugins.html", [
        [ "Type Plugins", "howto_plugins_types.html", null ],
        [ "Extension Plugins", "howto_plugins_extensions.html", null ]
      ] ]
    ] ],
    [ "Topics", "topics.html", "topics" ],
    [ "Data Structures", "annotated.html", [
      [ "Data Structures", "annotated.html", "annotated_dup" ],
      [ "Data Structure Index", "classes.html", null ],
      [ "Data Fields", "functions.html", [
        [ "All", "functions.html", "functions_dup" ],
        [ "Variables", "functions_vars.html", "functions_vars" ]
      ] ]
    ] ],
    [ "Files", "files.html", [
      [ "File List", "files.html", "files_dup" ],
      [ "Globals", "globals.html", [
        [ "All", "globals.html", "globals_dup" ],
        [ "Functions", "globals_func.html", "globals_func" ],
        [ "Variables", "globals_vars.html", null ],
        [ "Typedefs", "globals_type.html", null ],
        [ "Enumerations", "globals_enum.html", null ],
        [ "Enumerator", "globals_eval.html", null ],
        [ "Macros", "globals_defs.html", "globals_defs" ]
      ] ]
    ] ]
  ] ]
];

var NAVTREEINDEX =
[
"annotated.html",
"group__datatype.html#gga03198c9baa1040aa264c44bdabb321b5a22597e06f15965f82e1367125d0bf503",
"group__plugins_extensions.html#gaa0a02f5e90849fcf8522c835ae663ea4",
"group__plugins_types_xpath10.html#ga9e46eabe1ee84f3d6c8d413ab4d73ef6",
"group__schematree.html#a4e5868d676cb634aa75b125a0f741abf",
"group__schematree.html#ab068931cc450442b63f5b3d276ea4297",
"group__schematree.html#ga411c8d4050a0d7ce5d639a97c210ff57",
"group__trees.html#ga04b6899066799af43f59cd8fa79cac61",
"ipv6__prefix_8c.html",
"tree__data_8h.html#a8f41da26d9b46168dcf9ee0b8c04ff03"
];

var SYNCONMSG = 'click to disable panel synchronisation';
var SYNCOFFMSG = 'click to enable panel synchronisation';