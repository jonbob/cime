package ConfigMachine;
my $pkg_nm = 'ConfigMachines';

use strict;
use English;
use Cwd qw( getcwd abs_path chdir);
use IO::File;
use XML::LibXML;
use Data::Dumper;
use ConfigCase;
use File::Basename;

# Check for the existence of XML::LibXML in whatever perl distribution happens to be in use.
# If not found, print a warning message then exit.
eval {
    require XML::LibXML;
    XML::LibXML->import();
};
if($@)
{
    my $warning = <<END;
WARNING:
  The perl module XML::LibXML is needed for XML parsing in the CIME script system.
  Please contact your local systems administrators or IT staff and have them install it for
  you, or install the module locally.  

END
    print "$warning\n";
    exit(1);
}

#-----------------------------------------------------------------------------------------------
sub setMachineFile
{
    my ($machine, $cimeroot, $srcroot, $input_file) = @_;

    # Determine the machines specificaiton file and see if the
    # target machine is supported

    my $parser = XML::LibXML->new( no_blanks => 1);
    my $xml = $parser->parse_file($input_file);
    my @nodes = $xml->findnodes(".//entry[\@id=\"MACHINES_SPEC_FILE\"]/value");
    my $machines_file = $nodes[0]->textContent();
    $machines_file =~ s/\$CIMEROOT/$cimeroot/;
    $machines_file =~ s/\$SRCROOT/$srcroot/;
    (-f "$machines_file")  or  die "*** Cannot find supported machines file $machines_file ***\n";

    if ($machine =~ /(.*)_(.*)/){
	$machine = $1;
    }

    my $xml = $parser->parse_file($machines_file);
    my @nodes = $xml->findnodes(".//machine[\@MACH=\"$machine\"]");
    if (@nodes) {
	print "Found machine \"$machine\" in $machines_file \n";
    } else {
	print "ERROR ConfigMachine::setMachineFile: no match for machine $machine :\n";
	print "  - possible machine values are \n";
	listMachines( "$machines_file" );
	die "Exiting \n";
    }	    
    return $machines_file;
}

#-----------------------------------------------------------------------------------------------
sub setMachineValues
{
    # Set the parameters for the specified machine.  
    my ($file_config, $primary_component, $machine, $compiler, $print_flag, $cfg_ref) = @_;

    my $machines_file = $cfg_ref->get('MACHINES_SPEC_FILE');
    (-f "$machines_file")  or  die "*** Cannot find supported machines file $machines_file ***\n";
    my $machines_dir  = dirname($machines_file);

    # First Check if the target machine is supported
    if ($machine =~ /(.*)_(.*)/){
	$machine  = $1;
	$compiler = $2 unless defined($compiler);
    }

    my $xml = XML::LibXML->new( no_blanks => 1)->parse_file($machines_file);
    my @nodes = $xml->findnodes(".//machine[\@MACH=\"$machine\"]");
    if (@nodes) {
	print "Found machine \"$machine\" in $machines_file \n";
    } else {
	print "ERROR ConfigMachine::setMachineValues: no match for machine $machine :\n";
	print "  - possible machine values are \n";
	listMachines( "$machines_file" );
	die "Exiting \n";
    }	    

    $cfg_ref->set('COMPILER'     , "$compiler");
    $cfg_ref->set('MACH'         ,  $machine);
    $cfg_ref->set('MACHINES_FILE', "$machines_file");
    $cfg_ref->set('MACHDIR'      , "$machines_dir");

    # Set the machine values obtained from the $machines_file
    _set_machine_values($print_flag, $cfg_ref);

    # Check that compiler request for target machine matches a supported value
    # Or set default compiler - if not provided compiler request
    _check_machine_compilers($print_flag, $cfg_ref);

    if ($print_flag >= 2) { print "Machine specifier: $machine.\n"; }

    # Determine pio settings for target machine
    # Note that any pio settings that are grid or compset dependent will be overwritten
    # by the config_pio.xml settings for the primary component
    _setPIOsettings($file_config, $primary_component, $cfg_ref);

    if ($print_flag >= 2) { print "Set pio settings for $machine.\n"; }
}

#-------------------------------------------------------------------------------
sub listMachines
{
    # Print the list of supported machines
    my ($machine_file) = @_;

    my $parser = XML::LibXML->new( no_blanks => 1);
    my $xml = $parser->parse_file($machine_file);

    print ("  \n");
    print ("  MACHINES:  name (description)\n");

    foreach my $node ($xml->findnodes(".//machine")) {
	my $name = $node->getAttribute('MACH');
	foreach my $child ($node->findnodes("./*")) {
	    if ($child->nodeName() eq 'DESC') {
		my $desc = $child->textContent();
		print "    $name ($desc) \n";		
	    }
	}
    }
}

#-----------------------------------------------------------------------------------------------
#                               Private routines
#-----------------------------------------------------------------------------------------------
sub _set_machine_values
{
    # open the specified xml file
    my ($print_flag, $cfg_ref) = @_;

    my $machine       = $cfg_ref->get('MACH'); 
    my $machines_file = $cfg_ref->get('MACHINES_FILE');

    my $xml = XML::LibXML->new( no_blanks => 1)->parse_file($machines_file);
    my @machine_nodes = $xml->findnodes(".//machine[\@MACH=\"$machine\"]/*");
    if (@machine_nodes) 
    {
	foreach my $node (@machine_nodes) {
	    my $name  = $node->nodeName();
	    my $value = $node->textContent();
	    if ( ! $cfg_ref->is_valid_name($name) ) { 
		die "set_machine: invalid id $name in machine $machine file $machines_file exiting\n"; 
	    }
	    # allow for environment variables in the config_machines.xml file using $ENV{variablename} syntax
	    if ($value =~/^(.*)\$ENV{(.*)}(.*)$/){
		$value = $1.$ENV{$2}.$3;
	    }
	    $cfg_ref->set($name, $value);
	    print "cfg_ref: $name set to ".$cfg_ref->get($name)."  $value\n" if($print_flag==2);
	}
    } 
    else 
    {
	print "ERROR: ConfigMachine::_set_machine_values: no specifications contained for machine $machine :\n";
	die "exiting\n"; 
    }
}

#-------------------------------------------------------------------------------
sub _check_machine_compilers
{
    # Check that compiler request for target machine matches a supported value
    # Or set default compiler - if not provided compiler request

    my ($print_flag, $cfg_ref) = @_;

    my $machine   = $cfg_ref->get('MACH'); 
    my $caseroot  = $cfg_ref->get('CASEROOT');
    my $compiler  = $cfg_ref->get('COMPILER');

    my $compilers;
    if ($machine =~ /userdefined/){
	$cfg_ref->set('COMPILER', "USERDEFINED_required_build");
    } else { 
	$compilers = $cfg_ref->get('COMPILERS');
	my @compilers = split ",", $compilers, -1;
	if ($compiler) {
	    if (! ($machine =~ "generic")){
		my $found = 0;
		foreach my $comp (@compilers) {
		    if ($compiler eq $comp) {
			$found = 1;
		    }
		}
		if (!$found) {
		    my $sysmod = "rm -rf $caseroot";
		    system($sysmod) == 0 or die "ERROR: $sysmod failed: $?\n";
		    die "ERROR: compiler setting of $compiler does not match supported values of $compilers \n";
		}
	    }
	    $cfg_ref->set('COMPILER', "$compiler");
	    if ($print_flag >= 2) { print "Machine compiler specifier: $compiler\n"; }
	} else {
	    $compiler = $compilers[0];   
	    $cfg_ref->set('COMPILER', "$compiler");
	    if ($print_flag >= 2) { print "Machine compiler specifier: $compiler\n"; }
	}
    }
}

#-------------------------------------------------------------------------------
sub _setPIOsettings
{
    # Set pio settings from config_machines.xml and config_pio.xml file

    my ($file_config, $primary_component, $cfg_ref) = @_; 

    my $mach = $cfg_ref->get('MACH');
    my $machines_file = $cfg_ref->get('MACHINES_FILE');
    my $cimeroot = $cfg_ref->get('CIMEROOT');
    my $grid = $cfg_ref->get('GRID');

    # First Read the machines file for any non-default machine specific pio settings
    my $xml = XML::LibXML->new( no_blanks => 1)->parse_file($file_config);
    my @nodes = $xml->findnodes(".//machine[\@MACH=\"$mach\"]/pio/*");
    if (defined @nodes) {
	foreach my $node (@nodes) {
	    my $name  = $node->nodeName();
	    my $value = $node->textContent();
	    $cfg_ref->set($name, $value);
	}
    }

    # Second, determine the filename for grid and/or compset specific pio settings
    my $xml = XML::LibXML->new( no_blanks => 1)->parse_file($file_config);
    my @files = $xml->findnodes(".//entry[\@id=\"PIO_SPEC_FILE\"]/values/value[\@component=\"$primary_component\"]");
    if (! defined @files) {
	die " ERROR ConfigMachine::_setPIOsettings: no pio specification file found for $primary_component \n";
    }
    my $file = $files[0]->textContent();
    $file =~ s/\$CIMEROOT/$cimeroot/;

    # Third, set non-default grid and/or compsets specific settings
    my $xml = XML::LibXML->new( no_blanks => 1)->parse_file("$file");
    my @nodes = $xml->findnodes(".//mach[\@name=\"$mach\"]");
    my %pio_settings;
    foreach my $node (@nodes) {
	foreach my $child ($node->childNodes()) {
	    my $name  = $child->nodeName(); 
	    my $value = $child->textContent();
	    my $grid_attr = $child->getAttribute('grid');
	    if (! defined $pio_settings{$name}) {
		$pio_settings{$name} = $value;
		$cfg_ref->set($name, $pio_settings{$name});
	    } else {		
		if ((defined $grid_attr) && ($grid =~ m/$grid_attr/)) {
		    $pio_settings{$name} = $value;
		    $cfg_ref->set($name, $pio_settings{$name});
		}
	    }
	}
    }
}    

1; # to make use or require happy
