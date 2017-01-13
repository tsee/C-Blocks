#ifndef CB_CODE_PARSER_EXTRACTOR_H_
#define CB_CODE_PARSER_EXTRACTOR_H_

/* Logic related to scanning, parsing, and extracting the C code in
 * clex/cblock/csub/.... In future will likely include the C function
 * signature parsing logic. */

#include <EXTERN.h>
#include <perl.h>

#include <cb_c_blocks_data.h>

enum { IS_CBLOCK = 1, IS_CSHARE, IS_CLEX, IS_CSUB } keyword_type_list;

int cb_identify_keyword (char * keyword_ptr, STRLEN keyword_len);

void cb_extract_c_code(pTHX_ c_blocks_data *data, int keyword_type);

/* TODO: ideally, these wouldn't be public. */
void cb_fixup_xsub_name(pTHX_ c_blocks_data *data);
char * cb_replace_double_colons_with_double_underscores(pTHX_ SV * to_replace);

#endif