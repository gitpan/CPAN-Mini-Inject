package CPAN::Mini::Inject;

use strict;

use Env;
use Carp;
use LWP::Simple;
use File::Copy;
use File::Basename;
use CPAN::Checksums qw(updatedir);
use Compress::Zlib;
use CPAN::Mini;

=head1 NAME

CPAN::Mini::Inject - Inject modules into a CPAN::Mini mirror.

=head1 Version

Version 0.14

=cut

our $VERSION = '0.14';
our @ISA=qw( CPAN::Mini );

=head1 Synopsis

If you're not going to customize the way CPAN::Mini::Inject works, you
probably want to look at the mcpani command, instead.

    use CPAN::Mini::Inject;

    $mcpi=CPAN::Mini::Inject->new;
    $mcpi->parsecfg('t/.mcpani/config');

    $mcpi->add( module => 'CPAN::Mini::Inject', 
                authorid => 'SSORICHE', 
                version => ' 0.01', 
                file => 'mymodules/CPAN-Mini-Inject-0.01.tar.gz' )

    $mcpi->writelist;
    $mcpi->update_mirror;
    $mcpi->inject;

=head1 Description

CPAN::Mini::Inject uses CPAN::Mini to build or update a local CPAN mirror
then adds modules from your repository to it, allowing the inclusion
of private modules in a minimal CPAN mirror. 

=head1 Methods

Each method in CPAN::Mini::Inject returns a CPAN::Mini::Inject object which
allows method chaining. For example:

    my $mcpi=CPAN::Mini::Inject->new;
    $mcpi->pasrsecfg
         ->update_mirror
         ->inject;

=head2 new()

Create a new CPAN::Mini::Inject object.

=cut

sub new {
  my $class=shift;
  my $self={};
  bless $self,$class;
  return $self;
}

=head2 loadcfg()

loadcfg accepts a CPAN::Mini::Inject config file or if not defined
will search the following four places in order:

=over 4

=item * file pointed to by the environment variable MCPANI_CONFIG

=item * $HOME/.mcpani/config

=item * /usr/local/etc/mcpani

=item * /etc/mcpani

=back 


loadcfg sets the instance variable cfgfile to the file found or undef if
none is found.

 print "$mcpi->{cfgfile}\n"; # /etc/mcpani

=cut

sub loadcfg {
  my $self=shift;
  my $cfgfile=shift||_findcfg();

  croak 'Unable to find config file' unless($cfgfile); 
  $self->{cfgfile}=$cfgfile;
  return $self;
}

=head2 parsecfg()

parsecfg reads the config file stored in the instance variable cfgfile and
creates a hash in config with each setting.

  $mcpi->{config}{remote} # CPAN sites to mirror from.

parsecfg expects the config file in the following format:

 local: /www/CPAN
 remote: ftp://ftp.cpan.org/pub/CPAN ftp://ftp.kernel.org/pub/CPAN
 repository: /work/mymodules
 passive: yes
 dirmode: 0755

Description of options:

=over 4

=item * local 

location to store local CPAN::Mini mirror (*REQUIRED*)

=item * remote 

CPAN site(s) to mirror from. Multiple sites can be listed space separated. 
(*REQUIRED*)

=item * repository

Location to store modules to add to the local CPAN::Mini mirror.

=item * passive

Enable passive FTP.

=item * dirmode

Set the permissions of created directories to the specified mode. The default
value is based on umask if supported.

=back

If either local or remote are not defined parsecfg croaks.

=cut

sub parsecfg {
  my $self=shift;
  my $cfgfile=shift;
  
  delete $self->{config} if(defined($self->{config}));

  my %required=( local => 1, remote => 1 );

  $self->loadcfg($cfgfile) unless($self->{cfgfile});

  if(-r $self->{cfgfile}) {
    open(CFGFILE,$self->{cfgfile});
    while(<CFGFILE>) {
      next if(/^\s*#/);
      $self->{config}{$1}=$2 if(/([^:\s]+)\s*:\s*(.*)$/);
      delete $required{$1} if(defined($required{$1}));
    }
    close(CFGFILE);

    croak 'Required parameter(s): '.join(' ',keys(%required)) if(keys(%required));
  }
  return $self;
}

=head2 testremote()

Test each site listed in the remote parameter of the config file by performing
a get on each site in order for authors/01mailrc.txt.gz. The first site to
respond successfully is set as the instance variable site.

 print "$mcpi->{site}\n"; # ftp://ftp.cpan.org/pub/CPAN

C<testremote> accepts an optional parameter to enable verbose mode.

=cut

sub testremote {
  my $self=shift;
  my $verbose=shift;

  $self->{site}=undef if($self->{site});

  $ENV{FTP_PASSIVE}=1 if($self->_cfg('passive'));

  foreach my $site (split(/\s+/,$self->_cfg('remote'))) {
    $site.='/' unless($site=~m/\/$/);

    print "Testing site: $site\n" if($verbose);

    if(get($site.'authors/01mailrc.txt.gz')) {
      $self->{site}=$site;
      print "\n$site selected.\n" if($verbose);
      last;
    }
  }

  croak "Unable to connect to any remote site" unless($self->{site});
  
  return $self;
}

=head2 update_mirror()

This is a subclass of CPAN::Mini.

=cut

sub update_mirror {
  my $self=shift;
  my %options=@_;

  croak 'Can not write to local: '.$self->_cfg('local') 
    unless(-w $self->_cfg('local'));

  $ENV{FTP_PASSIVE}=1 if($self->_cfg('passive'));

  $options{local}||=$self->_cfg('local');
  $options{trace}||=0;
  $options{skip_perl}||=$self->_cfg('perl')||1;

  $self->testremote($options{trace}) unless($self->{site});
  $options{remote}||=$self->{site};

  $options{dirmode}||=oct($self->_cfg('dirmode')||sprintf('0%o',0777 &~ umask()));

  CPAN::Mini->update_mirror( %options );
}

=head2 add()

Add a new module to the repository. The add method copies the module file
into the repository with the same structure as a CPAN site. For example
CPAN-Mini-Inject-0.01.tar.gz is copied to MYCPAN/authors/id/S/SS/SSORICHE.
add creates the required directory structure below the repository.

=over 4

=item * module

The name of the module to add.

=item * authorid

CPAN author id. This does not have to be a real author id. 

=item * version

The modules version number.

=item * file

The tar.gz of the module.

=back

=head3 Example

  add( module => 'Module::Name', 
       authorid => 'AUTHOR', 
       version => 0.01, 
       file => './Module-Name-0.01.tar.gz' );

=cut

sub add {
  my $self=shift;
  my %options=@_;

  my $optionchk=_optionchk(\%options,qw/module authorid version file/);

  croak "Required option not specified: $optionchk" if($optionchk);
  croak "No repository configured" unless($self->_cfg('repository'));
  croak "Can not write to repository: ".$self->_cfg('repository')
    unless( -w $self->_cfg('repository') );
  croak "Can not read module file: $options{file}" unless( -r $options{file});

  my $modulefile=basename($options{file});
  $self->readlist unless(exists($self->{modulelist}));

  $options{authorid}=uc($options{authorid});
  $self->{authdir}=$self->_authordir($options{authorid},$self->_cfg('repository'));

  my $target=$self->_cfg('repository').'/authors/id/'.$self->{authdir}.'/'.basename($options{file});

  copy($options{file},dirname($target))
    or croak "Copy failed: $!";

  $self->_updperms($target);

  push(@{$self->{modulelist}},
    _fmtmodule($options{module},
      $self->{authdir}."/$modulefile",
      $options{version}
    )
  );

  return $self;
}

=head2 inject()

Insert modules from the repository into the local CPAN::Mini mirror. inject
copies each module into the appropriate directory in the CPAN::Mini mirror
and updates the CHECKSUMS file.

Passing a value to C<inject> enables verbose mode, which lists each module
as it's injected.

=cut

sub inject {
  my $self=shift;
  my $verbose=shift;

  my $dirmode=oct($self->_cfg('dirmode')) if($self->_cfg('dirmode'));
  $self->readlist unless(exists($self->{modulelist}));

  my %updatedir;
  foreach my $modline (@{$self->{modulelist}}) {
    my ($module,$version,$file)=split(/\s+/,$modline);
    my $target=$self->_cfg('local').'/authors/id/'.$file;
    my $source=$self->_cfg('repository').'/authors/id/'.$file;

    $updatedir{dirname($file)}=1;

    _mkpath( [ dirname($target) ],$dirmode ); 
    copy($source,dirname($target)) 
      or croak "Copy $source to ".dirname($target)." failed: $!";

    $self->_updperms($target);
    print "$target ... injected\n" if($verbose);
  }

  foreach my $dir (keys(%updatedir)) {
    my $authdir=$self->_cfg('local')."/authors/id/$dir";
    updatedir($authdir);
    $self->_updperms("$authdir/CHECKSUMS");
  }

  $self->updpackages;

  return $self;
}

=head2 updpackages()

Update the CPAN::Mini mirror's modules/02packages.details.txt.gz with the
injected module information.

=cut

sub updpackages {
  my $self=shift;

  my @modules=sort(@{$self->{modulelist}});
  my $cpanpackages=$self->_cfg('local').'/modules/02packages.details.txt.gz';
  my $newpackages=$self->_cfg('repository').'/02packages.details.txt.gz';

  my $gzread = gzopen($cpanpackages,'rb') 
    or croak "Cannot open local 02packages.details.txt.gz: $gzerrno";

  my $inheader=1;
  my $gzwrite = gzopen($newpackages,'wb') 
    or croak "Cannot open repository 02packages.details.txt.gz: $gzerrno";
  while($gzread->gzreadline($_)) {
    if($inheader) {
      $inheader=0 unless(/\S/);
      $gzwrite->gzwrite($_);
      next;
    }

    if(defined($modules[0]) && lc($modules[0]) lt lc($_)) {
      $gzwrite->gzwrite($modules[0]."\n");
      shift(@modules);
      redo;
    }
    if(defined($modules[0]) && lc($modules[0]) eq lc($_)) {
      shift(@modules);
      next;
    }
    $gzwrite->gzwrite($_);
  }
  $gzread->gzclose;
  $gzwrite->gzclose;
  copy($newpackages,$cpanpackages);
  $self->_updperms($cpanpackages);

}

=head2 readlist()

Load the repository's modulelist.

=cut

sub readlist {
  my $self=shift;

  $self->{modulelist}=undef;

  return $self unless(-e $self->_cfg('repository').'/modulelist');
  croak 'Can not read module list: '.$self->_cfg('repository').'/modulelist' 
    unless(-r $self->_cfg('repository').'/modulelist');

  open(MODLIST,$self->_cfg('repository').'/modulelist');
  while(<MODLIST>) {
    chomp;
    push(@{$self->{modulelist}},$_);
  }
  close(MODLIST);

  return $self;
}

=head2 writelist()

Write to the repository modulelist.

=cut

sub writelist {
  my $self=shift;

  croak 'Can not write module list: '.$self->_cfg('repository')."/modulelist ERROR: $!" unless(-w $self->{config}{repository}.'/modulelist' || -w $self->{config}{repository});
  return $self unless(defined($self->{modulelist}));

  open(MODLIST,'>'.$self->_cfg('repository').'/modulelist');
  for(sort(@{$self->{modulelist}})) {
    chomp;
    print MODLIST "$_\n";
  }
  close(MODLIST);

  $self->_updperms($self->_cfg('repository').'/modulelist');

  return $self;
}

sub _updperms {
  my ($self,$file)=@_;

  chmod(oct($self->_cfg('dirmode')) & 06666,$file) if($self->_cfg('dirmode'));
}

sub _optionchk {
  my ($options,@list)=@_;
  my @missing;

  foreach my $option (@list) {
    push(@missing, $option) unless(defined($$options{$option}));
  }

  return join(' ',@missing) if(@missing);
}

sub _findcfg {
  return $ENV{MCPANI_CONFIG} if(defined($ENV{MCPANI_CONFIG}) && -r $ENV{MCPANI_CONFIG});
  return "$ENV{HOME}/.mcpani/config" if(defined($ENV{HOME}) && -r "$ENV{HOME}/.mcpani/config");
  return '/usr/local/etc/mcpani' if(-r '/usr/local/etc/mcpani');
  return '/etc/mcpani' if(-r '/etc/mcpani');
  return undef; 
}

sub _authordir {
  my ($self,$author,$dir)=@_;

  foreach my $subdir ('authors','id',substr($author,0,1),substr($author,0,2),$author) {
    $dir.="/$subdir";
    unless(-e $dir) {
      mkdir $dir
        or croak "mkdir $subdir failed: $!";
      chmod(oct($self->_cfg('dirmode')),$dir) if($self->_cfg('dirmode'));
    }
  }

  return substr($author,0,1).'/'.substr($author,0,2).'/'.$author;
}

sub _mkpath {
  my $paths=shift;
  my $mode=shift;

  foreach my $path (@$paths) {
    my $partpath;
    foreach my $subdir (split("/",$path)) {
      $partpath.=$subdir;
      if(length($subdir) && not -e $partpath) {
        mkdir $partpath;
        chmod($mode,$partpath) if($mode);
      }
      $partpath.='/';
    }
  }
}

sub _fmtmodule {
  my ($module,$file,$version)=@_;

  $module.=' ' while(length($module)+length($version) < 39);

  return $module.$version."  $file";
}

sub _cfg { 
  $_[0]->{config}{$_[1]} 
}

=head1 See Also

L<CPAN::Mini>

=head1 Author

Shawn Sorichetti, C<< <ssoriche@coloredblocks.net> >>

=head1 Bugs

Please report any bugs or feature requests to
C<bug-cpan-mini-inject@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.  I will be notified, and then you'll automatically
be notified of progress on your bug as I make changes.

=head1 Copyright & License

Copyright 2004 Shawn Sorichetti, All Rights Reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of CPAN::Mini::Inject