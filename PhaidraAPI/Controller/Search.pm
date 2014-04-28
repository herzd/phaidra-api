package PhaidraAPI::Controller::Search;

use strict;
use warnings;
use v5.10;
use base 'Mojolicious::Controller';
use PhaidraAPI::Model::Search;
use PhaidraAPI::Model::Search::GSearchSAXHandler;
use Mojo::IOLoop::Delay;

sub triples {
	my $self = shift;
	
	my $query = $self->param('query');
	my $limit = $self->param('limit');
	
	my $search_model = PhaidraAPI::Model::Search->new;
	my $sr = $search_model->triples($self, $query, $limit);
	
	$self->render(json => $sr, status => $sr->{status});
}

sub search {
	my $self = shift;	
	my $from = 1;
	my $limit = 10;
	my $sort = 'uw.general.title,SCORE';
	my $reverse = '0';
	my $query;
	
	if(defined($self->param('q'))){	
		$query = $self->param('q');
	}
	unless(defined($query)){
		$self->render(json => { alerts => [{ type => 'danger', msg => 'Undefined query' }]} , status => 400) ;		
		return;
	}
	
	if(defined($self->param('from'))){	
		$from = $self->param('from');
	}
	
	if(defined($self->param('limit'))){	
		$limit = $self->param('limit');
	}
	
	if(defined($self->param('sort'))){	
		$sort = $self->param('sort');
	}
	
	if(defined($self->param('reverse'))){	
		$reverse = $self->param('reverse');
	}	
	
	my $search_model = PhaidraAPI::Model::Search->new;			
	
	$query = $search_model->build_query($self, $query);
	
	$self->render_later;
	my $delay = Mojo::IOLoop->delay( 
	
		sub {
			my $delay = shift;			
			$search_model->search($self, $query, $from, $limit, $sort, $reverse, $delay->begin);			
		},
		
		sub { 	
	  		my ($delay, $r) = @_;	
			#$self->app->log->debug($self->app->dumper($r));			
			$self->render(json => $r, status => $r->{status});	
  		}
	
	);
	$delay->wait unless $delay->ioloop->is_running;	
		
}

sub owner {
	my $self = shift;	
	my $from = 1;
	my $limit = 10;
	my $sort = 'fgs.lastModifiedDate,STRING';
	my $reverse = '0';
	
	unless(defined($self->stash('username'))){		
		$self->render(json => { alerts => [{ type => 'danger', msg => 'Undefined username' }]} , status => 400) ;		
		return;
	}
	
	if(defined($self->param('from'))){	
		$from = $self->param('from');
	}
	
	if(defined($self->param('limit'))){	
		$limit = $self->param('limit');
	}	
	
	
	if(defined($self->param('sort'))){	
		$sort = $self->param('sort');
	}
	
	if(defined($self->param('reverse'))){	
		$reverse = $self->param('reverse');
	}	
		
	
	my $search_model = PhaidraAPI::Model::Search->new;			
	
	my $query = "fgs.ownerId:".$self->stash('username').' AND NOT fgs.contentModel:"cmodel:Page"';
	
	$self->render_later;
	my $delay = Mojo::IOLoop->delay( 
	
		sub {
			my $delay = shift;
			$search_model->search($self, $query, $from, $limit, undef, undef, $delay->begin);			
		},
		
		sub { 	
	  		my ($delay, $r) = @_;	
			#$self->app->log->debug($self->app->dumper($r));			
			$self->render(json => $r, status => $r->{status});	
  		}
	
	);
	$delay->wait unless $delay->ioloop->is_running;	
		
}

sub collections_owner {
	my $self = shift;	
	my $from = 1;
	my $limit = 10;
	
	unless(defined($self->stash('username'))){		
		$self->render(json => { alerts => [{ type => 'danger', msg => 'Undefined username' }]} , status => 400) ;		
		return;
	}
	
	if(defined($self->param('from'))){	
		$from = $self->param('from');
	}
	
	if(defined($self->param('limit'))){	
		$limit = $self->param('limit');
	}		
	
	my $search_model = PhaidraAPI::Model::Search->new;			
	
	my $query = "fgs.ownerId:".$self->stash('username').' AND fgs.contentModel:"cmodel:Collection" AND NOT fgs.contentModel:"cmodel:Page"';
	
	$self->render_later;
	my $delay = Mojo::IOLoop->delay( 
	
		sub {
			my $delay = shift;
			$search_model->search($self, $query, $from, $limit, undef, undef, $delay->begin);			
		},
		
		sub { 	
	  		my ($delay, $r) = @_;	
			#$self->app->log->debug($self->app->dumper($r));			
			$self->render(json => $r, status => $r->{status});	
  		}
	
	);
	$delay->wait unless $delay->ioloop->is_running;	
		
}

1;
