package Bio::Brass::ReadSelection;

########## LICENCE ##########
# Copyright (c) 2014-2018 Genome Research Ltd.
#
# Author: CASM/Cancer IT <cgphelp@sanger.ac.uk>
#
# This file is part of BRASS.
#
# BRASS is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation; either version 3 of the License, or (at your option) any
# later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.
#
# 1. The usage of a range of years within a copyright statement contained within
# this distribution should be interpreted as being equivalent to a list of years
# including the first and last year specified and all consecutive years between
# them. For example, a copyright statement that reads ‘Copyright (c) 2005, 2007-
# 2009, 2011-2012’ should be interpreted as being identical to a statement that
# reads ‘Copyright (c) 2005, 2007, 2008, 2009, 2011, 2012’ and a copyright
# statement that reads ‘Copyright (c) 2005-2012’ should be interpreted as being
# identical to a statement that reads ‘Copyright (c) 2005, 2006, 2007, 2008,
# 2009, 2010, 2011, 2012’."
########## LICENCE ##########


use strict;
use warnings;

use Bio::DB::HTS;
use Carp;
use List::Util qw(first);
use File::Spec;
use File::Temp qw(tmpnam);
use Bio::Brass qw($VERSION);
use PCAP::Bam::Bas;

=head1 NAME

Bio::Brass::ReadSelection - select reads from within a BAM file region

=head1 SYNOPSIS

    use Bio::Brass::ReadSelection;

    $bam = Bio::Brass::ReadSelection->new($filename);
    ($k, $d) = $bam->write_local_reads($fh, @bedpe);

=head1 DESCRIPTION

=cut

use constant { PROPER_PAIRED => 0x2, UNMAPPED => 0x4, MATE_UNMAP => 0x8,
	       REVERSE_STRAND => 0x10, MATE_REVERSE_STRAND => 0x20,
	       NOT_PRIMARY_ALIGN => 0x100, VENDER_FAIL => 0x200,
	       DUP_READ => 0x400, SUPP_ALIGNMENT => 0x800
};

=head2 new

    $bam = Bio::Brass::ReadSelection->new($filename);

Opens the specified BAM|CRAM file and associated BAI|CSI|CRAI index file.
$filename is either the alignment filename or "ALIGNMENTS:INDEX" to also give the index
filename, in which case temporary symlinks will be created as necessary.

=cut

sub new {
    my ($class, $filename, $aligner_mode) = @_;
    my $self = {};

    $self->{filename} = $filename;
    $self->{aligner_mode} = $aligner_mode;

    my ($bam, $bai) = split /:/, $filename;
    my $bas;
    if (defined $bai && -e $bam && -e $bai) {
	# If both files exist, treat this as BAMFILE:BAIFILE explicit syntax
    }
    elsif (-e $bam && -e "$bam.bai") {
	# Index file is .bam.bai, so Bio::DB::HTS can use the files directly
	undef $bam;  undef $bai;
    }
    elsif (-e $bam && -e "$bam.csi") {
      # Index file is .bam.csi, so Bio::DB::HTS can use the files directly
      undef $bam;  undef $bai;
    }
		elsif (-e $bam && $bam =~ m/cram$/ && -e "$bam.crai") {
      # Alignment is cram and index file is .cram.crai, so Bio::DB::HTS can use the files directly
      undef $bam;  undef $bai;
    }
    else {
			# handle files which don't include bam/cram before index extension
			$bai = $bam;
			$bai =~ s{[.][^./]*$}{};
			if($bam =~ m/bam$/) {
				$bai .= '.bai';
				# doesn't matter if changed and not existing due to logic below
				$bai .= '.csi' unless(-e $bai);
			}
			elsif($bam =~ m/cram$/) {
				$bai .= '.crai';
			}
			if (-e $bam && -e $bai) {
			    # Index file is .bai|.csi|.crai, so Bio::DB::HTS will need symlinks
			}
			else {
			    # No index file present, so just fail with the original filename
			    undef $bam;  undef $bai;
			}
    }

    if (defined $bam) {
  $bas = File::Spec->rel2abs($bam.'.bas') if(-e $bam.'.bas');
	$bam = File::Spec->rel2abs($bam);
	$bai = File::Spec->rel2abs($bai);

	# This is an abuse of tmpnam(), which tries to ensure that "$base" does
	# not exist, but says nothing about "$base.bam" or "$base.bam.bai"
	my $base = tmpnam();
	my $aln_ext = 'bam';
	$aln_ext = 'cram' if($bam =~ m/cram$/);
	my $idx_ext = 'bam.bai';
	if($bai =~ m/csi$/) {
		$idx_ext = 'bam.csi';
	}
	elsif($bai =~ m/cram$/) {
		$idx_ext = 'cram.crai';
	}


	symlink $bam, "$base.$aln_ext"
	    or croak "can't symlink $bam to $base.$aln_ext: $!";
	unless (symlink $bai, "$base.$idx_ext") {
	    unlink "$base.$aln_ext";  # Ignore errors during destruction
	    croak "can't symlink $bai to $base.$idx_ext: $!";
	}
	unless (symlink $bas, "$base.$aln_ext.bas") {
	    unlink "$base.$aln_ext";  # Ignore errors during destruction
	    unlink "$base.$idx_ext";  # Ignore errors during destruction
	    croak "can't symlink $bas to $base.$aln_ext.bas: $!";
  }

	$self->{unlink_base} = $base;
	$filename = "$base.$aln_ext";
    }

    $self->{bam} = Bio::DB::HTS->new(-bam => $filename);

    my $max = 0;
    my %sample_names = ();

    foreach (split /\n/, $self->{bam}->header->text) {
      next unless /^\@RG/;
      if(/\tMI:(?:Z:)?(\d+)/){
        $max = $1 if $1 > $max;
      }
      $sample_names{$1}++    if(/\tSM:([^\t]+)/);
    }
    $max = insert_from_bas($filename) if($max == 0);

	warn "Multiple sample names detected in |$filename|" if scalar keys %sample_names > 1;

	my @names = keys %sample_names;

	$self->{sample_name} = $names[0] if scalar @names;
	$self->{maxmaxins} = $max;

    return bless $self, $class;
}

sub insert_from_bas {
  my $filename = shift;
  my $max_mi = 0;
  my $bas = "$filename.bas";
  if(-e $bas && -s _) {
    my $bas_ob = PCAP::Bam::Bas->new($bas);
    my @groups = $bas_ob->read_groups;
    for my $rg_id(@groups) {
      my $mean_insert_size = $bas_ob->get($rg_id, 'mean_insert_size');
      my $insert_size_sd = $bas_ob->get($rg_id, 'insert_size_sd');
      my $mi = int( $mean_insert_size + (2 * $insert_size_sd) );
      $max_mi = $mi if($mi > $max_mi);
    }
  }
  return $max_mi;
}

sub maxmaxins {
  return shift->{maxmaxins};
}

sub DESTROY {
    my ($self) = @_;
    if (exists $self->{unlink_base}) {
	my $base = $self->{unlink_base};
	  # Ignore errors during destruction
	unlink "$base.bam", "$base.bam.bai", "$base.bam.csi", "$base.cram", "$base.cram.crai";
    }
}

=head2 _get_reads

  ($kept, $discarded) = $self->_get_reads($self, $chr, $pos5, $pos3, $strand, $k, $d, $q);

Collects reads in this region into:

  $k : potentially keep
  $d : discarded
  $q : Query name of poor quality single end mapped

$k and $d are hashes to ensure that reads aren't collected twice
when querying close groups

$q is used to remove any unmapped reads from the set that are only included due to a very poor
quality mapping of the single end.

=cut

sub _get_reads {
  my ($self, $chr, $pos5, $pos3, $strand, $k, $q, $abort_reads) = @_;

  my $normalpos5 = $pos5 - $self->{maxmaxins};
  my $normalpos3 = $pos3 + $self->{maxmaxins};

  my $mutpos5 = ($strand eq '+')? $normalpos5 : $pos5;
  my $mutpos3 = ($strand eq '+')? $pos3 : $normalpos3;

  my $kept = 0;
  my $discarded = 0;
  my $aligner = $self->{aligner_mode};
  $self->{'bam'}->fetch("$chr:$normalpos5-$normalpos3", sub {
    return if($kept >= $abort_reads);
    my $a = $_[0];
    my $flags = $a->flag;
    ## Ignore reads if they match the following flags:
    return if $flags & NOT_PRIMARY_ALIGN;
    return if $flags & VENDER_FAIL;
    # return if $flags & DUP_READ;
    return if $flags & SUPP_ALIGNMENT;

    my $emit = 1;
    if($aligner eq 'aln') {
      if ($flags & PROPER_PAIRED) {
        # Proper
        my $matepos = $a->mate_start;
        $emit = ($normalpos5 <= $matepos && $matepos <= $normalpos3);
      }
      elsif (($flags & UNMAPPED) == 0) {
        # Discordant, or the mapped mate of a potential split read
        my $flag_strand = ($flags & REVERSE_STRAND)? '-' : '+';
        my $pos = $a->start;
        $emit = ($flag_strand eq $strand &&
        $mutpos5 <= $pos && $pos <= $mutpos3);
      }
      else {
        # Unmapped -- split read
        my $mate_strand = ($flags & MATE_REVERSE_STRAND)? '-' : '+';
        my $matepos = $a->mate_start;
        $emit = ($mate_strand eq $strand &&
        $mutpos5 <= $matepos && $matepos <= $mutpos3);
      }
    }

    # if the mapping qual is poor chances are they will disrupt the result
    if(!($flags & UNMAPPED) &&  $a->qual < 10) {
      $emit = 0;
      push @{$q}, $a->qname if(($flags & MATE_UNMAP));
    }

    if ($emit) {
      push @{$k->{$a->qname}}, join "\t", (split /\t/, $a->tam_line)[0..10];
      $kept++;
    }
    else {
      $discarded++;
    }
  });

  return ($kept, $discarded);
}

=head2 write_local_reads

    ($kept, $discarded) = $bam->write_local_reads($fh, @bedpe);

Writes alignment records in the vicinity of either side of the specified BEDPE
record to the specified output file.  Returns the numbers of records eventually
emitted and in the vicinity but discarded due to strand and mappedness rules.

=cut

sub write_local_reads {
  my ($self, $out, $chrl, $lstart, $lend, $chrh, $hstart, $hend,
	    undef, undef, $strandl, $strandh) = @_;

  my $abort_reads = 20_000;
  my ($k_reads, $q_pairs) = ({},[]);

  my ($k1, $d1) = $self->_get_reads($chrl, $lstart+1, $lend, $strandl, $k_reads, $q_pairs, $abort_reads);
  return (0,$k1+$d1) if($k1 > $abort_reads); # artificially block extreme depth from assembly

  my ($k2, $d2) = $self->_get_reads($chrh, $hstart+1, $hend, $strandh, $k_reads, $q_pairs, $abort_reads);
  return (0,$k2+$d2) if($k2 >= $abort_reads); # artificially block extreme depth from assembly

  my $k_count = 0;
  for my $pair(sort keys %{$k_reads}) {
    # unmapped mates which had a poor quality mapping
    # are discarded by this section
    next if(first { $_ eq $pair } @{$q_pairs});
    my @keep = @{$k_reads->{$pair}};
    print $out join "\n", @keep;
    print $out "\n";
    $k_count+= scalar @keep;
  }
  return ($k_count, $d1 + $d2);
}

=head2 sample_name

    $samle_name = $bam->sample_name();

Returns the sample name read from the header of the bam file. Currently only expects
one sample name per file but will warn if more than one sample is found and return a
single random sample.

=cut

sub sample_name {
	return shift->{sample_name};
}

=head1 SEE ALSO

=over 4

=item L<Bio-SamTools>

Lincoln Stein's Perl interface to the samtools SAM/BAM library.
This package requires at least version 1.35.

=back

=head1 AUTHOR

John Marshall E<lt>jm18@sanger.ac.ukE<gt>

=cut

1;
