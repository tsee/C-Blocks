package C::Blocks::XSWrapper;
use strict;
use warnings;
use ExtUtils::Typemaps;

# TODO The parser module can be done away with once there's a better signature
# syntax and parser...
use C::Blocks::XSWrapper::Parser;

SCOPE: {
	my $core_typemap;
	sub _get_core_typemap {
		return $core_typemap if $core_typemap;

		my @tm;
		foreach my $dir (@INC) {
			my $file = File::Spec->catfile($dir, ExtUtils => 'typemap');
			unshift @tm, $file if -e $file;
		}

		$core_typemap = ExtUtils::Typemaps->new();
		foreach my $typemap_loc (@tm) {
			next unless -f $typemap_loc;
			# skip directories, binary files etc.
			warn("Warning: ignoring non-text typemap file '$typemap_loc'\n"), next
				unless -T $typemap_loc;

			$core_typemap->merge(file => $typemap_loc, replace => 1);
		}

		# Override core typemaps with custom function-based replacements.
		# This is because GCC compiled functions are likely faster than inlined code in TCC.
		$core_typemap->merge(replace => 1, typemap => $XS::TCC::Typemaps::Typemap);

		return $core_typemap;
	} # end _get_core_typemap
} # end SCOPE




sub generate_xs {
	my ($package, $function_name, $code_top, $code_main, $code_bottom) = @_;

	# FIXME we do some really awful code munging here. That's just as a temporary
	# workaround so we have things clean for parsing the function signature. This
	# should eventually be done before even calling this function such that none
	# of this terrible stuff is necessary.

	# Second line is the declaration. (sigh)
	my @tmp = split /\n/, $code_main;
	my $declaration = splice(@tmp, 1, 1);
	shift @tmp;
	$code_main = join "\n", @tmp;
	$declaration =~ s/\)/) {/;

	my $func_info = C::Blocks::XSWrapper::Parser::extract_function_metadata($declaration, {first_only => 1});
	croak("Couldn't find function declaration in csub code")
		if not keys %{$func_info->{functions}};

	# We're explicitly dealing with one function only, so reduce to that
	my @funcs = values(%{$func_info->{functions}});
	$func_info = shift @funcs;

	my $c_func_code = "STATIC " . $func_info->{return_type} . " "
				. $function_name . "("
				. join( ", ",
					map {$func_info->{arg_types}[$_] . " " . $func_info->{arg_names}[$_]}
					0..$#{$func_info->{arg_names}} )
				. ") {\n";
	$c_func_code .= $code_main . "\n";
	#$c_func_code .= "}";

	# TODO: Once there's a good way for users to supply custom typemaps,
	#       there should be merge logic here (see XS::TCC::tcc_inline).
	my $typemap = _get_core_typemap();

	my $xs_code = _gen_single_function_xs_wrapper($package, $function_name, $code_main, $func_info, $typemap);

	return $c_func_code . "\n" . $xs_code;
}

sub _gen_single_function_xs_wrapper {
  my ($package, $cfun_name, $code_main, $fun_info, $typemap) = @_;

  my $code_ary = [];
  my $arg_names = $fun_info->{arg_names};
  my $nparams = scalar(@$arg_names);
  my $arg_names_str = join ", ", map {s/\W/_/; $_} @$arg_names;

  # Return type and output typemap preparation
  my $ret_type = $fun_info->{return_type};
  my $is_void_function = $ret_type eq 'void';
  my $retval_decl = $is_void_function ? '' : "$ret_type RETVAL;";

  my $out_typemap;
  my $outputmap;
  my $dxstarg = "";
  if (not $is_void_function) {
    $out_typemap = $typemap->get_typemap(ctype => $ret_type);
    $outputmap = $out_typemap
                 ? $typemap->get_outputmap(xstype => $out_typemap->xstype)
                 : undef;
    Carp::croak("No output typemap found for return type '$ret_type'")
      if not $outputmap;
    # TODO implement TARG optimization below
    #$dxstarg = $outputmap->targetable ? " dXSTARG;" : "";
  }

  # Emit function header and declarations
  (my $xs_pkg_name = $package) =~ s/:/_/g;
  my $xs_fun_name = "xs_${xs_pkg_name}__$cfun_name";
  push @$code_ary, <<FUN_HEADER;
XS_EXTERNAL($xs_fun_name); /* prototype to pass -Wmissing-prototypes */
XS_EXTERNAL($xs_fun_name)
{
  dVAR; dXSARGS;$dxstarg
  if (items != $nparams)
    croak_xs_usage(cv,  "$arg_names_str");
  /* PERL_UNUSED_VAR(ax); */ /* -Wall */
  /* SP -= items; */
  {
    $retval_decl


FUN_HEADER

  my $do_pass_threading_context = $fun_info->{need_threading_context};

  # emit input typemaps
  my @input_decl;
  my @input_assign;
  for my $argno (0..$#{$fun_info->{arg_names}}) {
    my $aname = $fun_info->{arg_names}[$argno];
    my $atype = $fun_info->{arg_types}[$argno];
    (my $decl_type = $atype) =~ s/^\s*const\b\s*//;

    my $tm = $typemap->get_typemap(ctype => $atype);
    my $im = !$tm ? undef : $typemap->get_inputmap(xstype => $tm->xstype);

    Carp::croak("No input typemap found for type '$atype'")
      if not $im;
    my $imcode = $im->cleaned_code;

    my $vars = {
      Package => $package,
      ALIAS => $cfun_name,
      func_name => $cfun_name,
      Full_func_name => $cfun_name,
      pname => $package . "::" . $cfun_name,
      type => $decl_type,
      ntype => $decl_type,
      arg => "ST($argno)",
      var => $aname,
      init => undef,
      # FIXME some of these are guesses at their true meaning. Validate in EU::PXS
      num => $argno,
      printed_name => $aname,
      argoff => $argno,
    };

    # FIXME do we want to support the obscure ARRAY/Ptr logic (subtype, ntype)?
    my $out = ExtUtils::ParseXS::Eval::eval_input_typemap_code(
      $vars, qq{"$imcode"}, $vars
    );

    $out =~ s/;\s*$//;
    if ($out =~ /^\s*\Q$aname\E\s*=/) {
      push @input_decl, "    $decl_type $out;";
    }
    else {
      push @input_decl, "    $decl_type $aname;";
      push @input_assign, "    $out;";
    }
  }
  push @$code_ary, @input_decl, @input_assign;

  # emit function call
  my $fun_call_assignment = $is_void_function ? "" : "RETVAL = ";
  my $arglist = join ", ",  @{ $fun_info->{arg_names} };
  my $threading_context = "";
  if ($do_pass_threading_context) {
     $threading_context = scalar(@{ $fun_info->{arg_names} }) == 0
                          ? "aTHX " : "aTHX_ ";
  }
  push @$code_ary, "    ${fun_call_assignment}$cfun_name($threading_context$arglist);\n";

  # emit output typemap
  if (not $is_void_function) {
    my $omcode = $outputmap->cleaned_code;
    my $vars = {
      Package => $package,
      ALIAS => $cfun_name,
      func_name => $cfun_name,
      Full_func_name => $cfun_name,
      pname => $package . "::" . $cfun_name,
      type => $ret_type,
      ntype => $ret_type,
      arg => "ST(0)",
      var => "RETVAL",
    };

    # FIXME do we want to support the obscure ARRAY/Ptr logic (subtype, ntype)?

    # TODO TARG ($om->targetable) optimization!
    my $out = ExtUtils::ParseXS::Eval::eval_output_typemap_code(
      $vars, qq{"$omcode"}, $vars
    );
    push @$code_ary, "    ST(0) = sv_newmortal();";
    push @$code_ary, "    " . $out;
  }


  my $nreturnvalues = $is_void_function ? 0 : 1;
  push @$code_ary, <<FUN_FOOTER;
  }
  XSRETURN($nreturnvalues);
}
FUN_FOOTER

  #return($xs_fun_name);
  return join "\n", @$code_ary;
}




1;

