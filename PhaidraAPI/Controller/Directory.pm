package PhaidraAPI::Controller::Directory;

use strict;
use warnings;
use v5.10;

use base 'Mojolicious::Controller';

sub get_org_units {
    my $self = shift;  	

	my $parent_id = $self->param('parent_id');
	my $namespace = $self->param('namespace');
	
	my %vocabulary;
				
	my $langs = $self->app->config->{directory}->{org_units_languages};
	foreach my $lang (@$langs){
				
		my $res = $self->app->directory->get_org_units($self, $parent_id, $lang);
		if(exists($res->{alerts})){
			if($res->{status} != 200){
				# there are only alerts
				$self->render(json => { alerts => $res->{alerts} }, status => $res->{status} ); 
			}else{
				# there are results and alerts
				$self->render(json => { org_units => $res->{org_units}, alerts => $res->{alerts}}, status => 200 );	
			}
		}
				
		my $org_units = $res->{org_units};
				
		foreach my $u (@$org_units){	
			$vocabulary{'terms'}->{$u->{value}}->{uri} = $namespace.$u->{value};
			$vocabulary{'terms'}->{$u->{value}}->{$lang} = $u->{name};								
		}											
	}
	my @termarray;
	while ( my ($key, $element) = each %{$vocabulary{'terms'}} ){	
		push @termarray, $element;
	}
	
	# there are only results
    $self->render(json => { terms => \@termarray }, status => 200 );
}

sub get_study_plans {
    my $self = shift;  	

	my $res = $self->app->directory->get_study_plans($self);
	
	if(exists($res->{alerts})){
		if($res->{status} != 200){
			# there are only alerts
			$self->render(json => { alerts => $res->{alerts} }, status => $res->{status} ); 
		}else{
			# there are results and alerts
			$self->render(json => { org_units => $res->{org_units}, alerts => $res->{alerts}}, status => 200 );	
		}
	}
	
	# there are only results
    $self->render(json => { study_plans => $res->{study_plans} }, status => 200 );
}

sub get_study {
    my $self = shift;  	

	my $splid = $self->param('splid');
	my $level = $self->param('level');
	my @ids = $self->param('ids');
=cut	
	if(ref($ids) ne 'ARRAY'){
		my @arr;
		push @arr, $ids;
		$ids = \@arr;
	}
=cut	
	$self->app->log->debug($self->app->dumper(\@ids));
	my $res = $self->app->directory->get_study($self, $splid, \@ids);
	
	if(exists($res->{alerts})){
		if($res->{status} != 200){
			# there are only alerts
			$self->render(json => { alerts => $res->{alerts} }, status => $res->{status} ); 
		}else{
			# there are results and alerts
			$self->render(json => { org_units => $res->{org_units}, alerts => $res->{alerts}}, status => 200 );	
		}
	}
	
	unshift $res->{'study'}, { value => '-100', name => $self->l('none') };
	
	# there are only results
    $self->render(json => { 'study' => $res->{'study'}, level => $level }, status => 200 );
}

1;
