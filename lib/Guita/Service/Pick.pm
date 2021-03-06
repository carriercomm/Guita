package Guita::Service::Pick;
use prelude;
use parent qw(Guita::Service);

use Guita::Git;
use Path::Class;
use Fcntl qw(:flock SEEK_END);

sub collect_files_for {
    my ($class, $pick, $sha) = @_;

    my $git = Guita::Git->new_with_work_tree(
        dir(GuitaConf('repository_base'))->subdir($pick->id),
    );
    return unless $git;

    my $files = [];
    try {
        $git->traverse_tree( $sha, sub {
            my ($obj, $path) = @_;
            push @$files, +{ # Fileオブジェクトにする
                name => $path,
                blob => $git->blob_with_contents($obj->objectish),
            };
        });
    }
    catch {
        warn $_;
    };
    return unless @$files; # 例外返す

    return $files;
}

sub fill_from_git {
    my ($class, $pick, $sha) = @_;
    return unless $pick;

    my $author = $class->dbixl->table('user')->search({ id => $pick->user_id })->single
        || Guita::Model::User::Guest->new;

    # work_treeの存在チェック?
    my $git = Guita::Git->new_with_work_tree(
        dir(GuitaConf('repository_base'))->subdir($pick->id)->stringify,
    );
    my $logs = $git->logs(10, 'HEAD');
    $sha ||= $logs->[0]->objectish;

    $pick->author($author);
    $pick->logs($logs);
    $pick->files($class->collect_files_for($pick, $sha));

    return $pick;
}

sub fill_users {
    my ($class, $picks) = @_;
    return unless $picks;

    my @authors = $class->dbixl->table('user')->search({
        id => { -in => [ map { $_->user_id } @$picks ] },
    })->all;

    my $author_by_id = {
        map { ( $_->id => $_ )} @authors,
    };

    for my $pick (@$picks) {
        $pick->author( $author_by_id->{$pick->user_id} || Guita::Model::User::Guest->new)
    }

    return $picks;
}

sub file_content_at {
    my ($class, $pick, $sha, $path) = @_;
    return unless $pick;

    my $git = Guita::Git->new_with_work_tree(
        dir(GuitaConf('repository_base'))->subdir($pick->id)->stringify,
    );

    my $object = $git->object_for_path($sha, $path);
    return $git->cat_file($object->objectish);
}

sub create {
    my ($class, $user, $filename, $content, $description) = @_;

    my $pick = $class->dbixl->table('pick')->insert({
        user_id     => $user->id,
        description => $description,
    });

    # bare でうまいことしたいなぁ
    my $work_tree = dir(GuitaConf('repository_base'))->subdir($pick->id)->stringify;
    my $git = Guita::Git->init($work_tree);
    $git->config(qw(receive.denyCurrentBranch ignore));

    # まともなエラー処理

    # textareaの内容をファイルに書きだして
    my $file = dir($work_tree)->file($filename);
    my $fh = $file->openw;
    $content = $content . ''; # copy
    $content =~ s/\r\n/\n/g;
    print $fh $content;
    close $fh;

    # add して
    $git->add($file->stringify);

    # commit
    $git->commit('edited in guita web form', {author => $user});

    return $pick;
}

sub edit {
    my ($class, $pick, $author, $codes, $description) = @_;
    # TODO ファイルがなくなったら削除する

    my $work_tree = dir(GuitaConf('repository_base'))->subdir($pick->id);
    my $git = Guita::Git->new_with_work_tree($work_tree->stringify);

    $git->run(qw(reset --hard)); # 不要?

    for my $code (@$codes) {
        my $file = $work_tree->file($code->{path});
        next unless -e $file;

        $code =~ s/\r\n/\n/g;

        my $fh = $file->openw;
        flock($fh, LOCK_EX) or croak "Cannot lock $code->{path}: $!\n";
        seek($fh, 0, SEEK_END) or croak "Cannot seek - $!\n"; # ロック中になにか書き込まれてたらいけないので
        print $fh $code->{content};
        flock($fh, LOCK_UN) or croak "Cannot unlock $code->{path}: $!\n";
        close $fh;

        # add して
        $git->add($file->stringify);
    }

    $git->commit('edited in guita web form', {author => $author});

    $pick->update({
        description => $description,
        modified    => $class->dbixl->now(),
    });
}

sub list {
    my ($class, $args) = @_;

    my @picks = $class->dbixl->table('pick')
        ->limit($args->{limit})
        ->offset($args->{offset})
        ->all;

    return $class->to_viewable(\@picks);
}

sub count {
    my ($class) = @_;
    return $class->dbixl->table('pick')->select->count,
}

sub list_for_user {
    my ($class, $args) = @_;

    my @picks = $class->dbixl->table('pick')
        ->search({ user_id => $args->{user_id} })
        ->limit($args->{limit})
        ->offset($args->{offset})
        ->all;

    return $class->to_viewable(\@picks);
}

sub count_for_user {
    my ($class, $user_id) = @_;
    return $class->dbixl->table('pick')
        ->search({user_id => $user_id})->count,
}

sub to_viewable {
    my ($class, $picks) = @_;

    return [
        map {
            my $pick = $_;
            my $work_tree = dir(GuitaConf('repository_base'))->subdir($pick->id);

            my $git = Guita::Git->new_with_work_tree( $work_tree->stringify );
            my $tree = $git->tree_with_children('HEAD');

            my $blob_with_name = $tree->blobs_list->[0];
            $blob_with_name ? +{
                pick   => $pick,
                name   => $blob_with_name->{name},
                blob   => $git->blob_with_contents($blob_with_name->{obj}->objectish),
            } : ()
        }
        grep {
            my $pick = $_;
            my $work_tree = dir(GuitaConf('repository_base'))->subdir($pick->id);
            -e $work_tree->stringify;
        } @$picks
    ];
}

1;
