package PhaidraAPI::Controller::Imageserver;

use strict;
use warnings;
use v5.10;
use Mango 0.24;
use base 'Mojolicious::Controller';
use Mojo::JSON qw(encode_json decode_json);
use Mojo::ByteStream qw(b);
use Digest::SHA qw(hmac_sha1_hex);
use PhaidraAPI::Model::Object;

sub process {

  my $self = shift;  

  my $pid = $self->stash('pid');

  my $hash = hmac_sha1_hex($pid, $self->app->config->{imageserver}->{hash_secret});

  $self->paf_mongo->db->collection('jobs')->insert({pid => $pid, agent => "pige", status => "new", idhash => $hash, created => time });      

  my $res = $self->paf_mongo->db->collection('jobs')->find({pid => $pid})->sort({ "created" => -1})->next;

  $self->render(json => $res, status => 200);

}

sub process_pids {

  my $self = shift;  

  my $pids = $self->param('pids');
  unless(defined($pids)){
    $self->render(json => { alerts => [{ type => 'danger', msg => 'No pids sent' }]} , status => 400) ;
    return;
  }

  if(ref $pids eq 'Mojo::Upload'){
    $self->app->log->debug("Pids sent as file param");
    $pids = $pids->asset->slurp;
    $pids = decode_json($pids);
  }else{
    $pids = decode_json(b($pids)->encode('UTF-8'));
  }

  my @results;
  for my $pid (@{$pids->{pids}}){

    # create new job to process image
    my $hash = hmac_sha1_hex($pid, $self->app->config->{imageserver}->{hash_secret});    
    $self->paf_mongo->db->collection('jobs')->insert({ pid => $pid, agent => "pige", status => "new", idhash => $hash, created => time });

    # create a temporary hash for the image to hide the real hash in case we want to forbid access to the picture
    my $tmp_hash = hmac_sha1_hex($hash, $self->app->config->{imageserver}->{tmp_hash_secret});
    $self->mango->db->collection('imgsrv.hashmap')->insert({ pid => $pid, idhash => $hash, tmp_hash => $tmp_hash, created => time });    
    
    push @results, { pid => $pid, idhash => $hash, tmp_hash => $tmp_hash };
  }

  $self->render(json => \@results, status => 200);

}

sub status {

  my $self = shift;  

  my $pid = $self->stash('pid');

  my $res = $self->paf_mongo->db->collection('jobs')->find({pid => $pid})->sort({ "created" => -1})->next;

  $self->render(json => $res, status => 200);

}


sub tmp_hash {

  my $self = shift;  

  my $pid = $self->stash('pid');

  # check rights
  my $object_model = PhaidraAPI::Model::Object->new;
  my $rres = $object_model->get_datastream($self, $pid, 'READONLY', $self->stash->{basic_auth_credentials}->{username}, $self->stash->{basic_auth_credentials}->{password});
  if($rres->{status} eq '404'){
      
    # it's ok
    my $res = $self->mango->db->collection('imgsrv.hashmap')->find_one({pid => $pid});
    if(!defined($res) || !exists($res->{tmp_hash})){
      # if we could not find the temp hash, look into the jobs if the image isn't there as processed
      my $res1 = $self->paf_mongo->db->collection('jobs')->find({pid => $pid})->sort({ "created" => -1})->next;
      if(!defined($res1) || $res1->{status} ne 'finished'){
        # if it isn't then this image isn't known to imageserver
        $self->render(json => { alerts => [{ type => 'info', msg => 'Not found in imageserver' }]}, status => 404);
        return;
      }else{        
        # if it is, create the temp hash
        if($res1->{idhash}){
          my $tmp_hash = hmac_sha1_hex($res1->{idhash}, $self->app->config->{imageserver}->{tmp_hash_secret});
          $self->mango->db->collection('imgsrv.hashmap')->insert({ pid => $pid, idhash => $res1->{idhash}, tmp_hash => $tmp_hash, created => time });    
          $self->render(text => $tmp_hash, status => 200);
          return;
        }        
      }
      
    }else{
      $self->render(text => $res->{tmp_hash}, status => 200);
      return;
    }


  }else{
     $self->render(json => {}, status => 403);
     return;
  }    

}

sub get {

  my $self = shift;  

  #my $pid = $self->stash('pid');
      
  my $res = { alerts => [], status => 200 };

  my $url = Mojo::URL->new;

  $url->scheme($self->app->config->{imageserver}->{scheme});
  $url->host($self->app->config->{imageserver}->{host});
  $url->path($self->app->config->{imageserver}->{path});

  my $isr = $self->app->config->{imageserver}->{image_server_root};

  my $p;
  my $p_name;
  my $params = $self->req->params->to_hash;
  $self->app->log->debug("XXXXXXXXXXXXX 1 ".$self->app->dumper($params));
  for my $param_name ('FIF','IIIF','Zoomify','DeepZoom') {
    if(exists($params->{$param_name})){          
      $p = $params->{$param_name};
      $p_name = $param_name;
      last;
    }
  }

  unless($p){
    $self->render(json => { alerts => [{ type => 'danger', msg => 'Cannot find IIIF, Zoomify or DeepZoom parameter' }]} , status => 400);
  }

  # get pid
  $p =~ m/([a-z]+:[0-9]+)\.tif/;
  my $pid = $1;

  # check rights        
  my $object_model = PhaidraAPI::Model::Object->new;
  my $rres = $object_model->get_datastream($self, $pid, 'READONLY', $self->stash->{basic_auth_credentials}->{username}, $self->stash->{basic_auth_credentials}->{password});
  unless($rres->{status} eq '404'){
    $self->render(json => {}, status => 403);
    return;
  }

  # infer hash
  my $hash = hmac_sha1_hex($pid, $self->app->config->{imageserver}->{hash_secret});    
  my $root = $self->app->config->{imageserver}->{image_server_root};
  my $first = substr($hash, 0, 1);
  my $second = substr($hash, 1, 1);
  my $imgpath = "$root/$first/$second/$hash.tif";

  # add leading slash if missing
  $p =~ s/^\/*/\//;
  # replace pid with hash
  $p =~ s/[a-z]+:[0-9]+\.tif/$imgpath/;

  $params->{$p_name} = $p;

  $url->query($params);
$self->app->log->debug("XXXXXXXXXXXXX ".$url->to_string);
$self->app->log->debug("XXXXXXXXXXXXX ".$self->app->dumper($url));
$self->app->log->debug("XXXXXXXXXXXXX ".$self->app->dumper($params));
  $self->render_later;    
  $self->ua->get( $url => sub { my ($ua, $tx) = @_; $self->tx->res($tx->res); $self->rendered; } );
 
}

1;
