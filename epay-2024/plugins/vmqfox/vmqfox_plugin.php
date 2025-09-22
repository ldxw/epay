<?php

class vmqfox_plugin
{
	static public $info = [
		'name'        => 'vmqfox', //支付插件英文名称，需和目录名称一致，不能有重复
		'showname'    => 'V免签Fox', //支付插件显示名称
		'author'      => 'V免签Fox', //支付插件作者
		'link'        => 'https://github.com/hulisang/vmqfox-backend', //支付插件作者链接
		'types'       => ['alipay','qqpay','wxpay'], //支付插件支持的支付方式，可选的有alipay,qqpay,wxpay,bank
		'inputs' => [ //支付插件要求传入的参数以及参数显示名称，可选的有appid,appkey,appsecret,appurl,appmchid
			'appurl' => [
				'name' => '接口地址',
				'type' => 'input',
				'note' => '必须以http://或https://开头，以/结尾',
			],
			'appid' => [
				'name' => '商户ID',
				'type' => 'input',
				'note' => '如果不需要商户ID，随便填写即可',
			],
			'appkey' => [
				'name' => '通讯密钥',
				'type' => 'input',
				'note' => '',
			],
		],
		'select' => null,
		'note' => '', //支付密钥填写说明
		'bindwxmp' => false, //是否支持绑定微信公众号
		'bindwxa' => false, //是否支持绑定微信小程序
	];

	static public function submit(){
		global $siteurl, $channel, $order, $ordername, $sitename, $conf;

		if($order['typename']=='alipay'){
			$paytype='2';
		}elseif($order['typename']=='qqpay'){
			$paytype='4';
		}elseif($order['typename']=='wxpay'){
			$paytype='1';
		}elseif($order['typename']=='bank'){
			$paytype='3';
		}
		
		// vmqfox使用RESTful API接口
		$apiurl = $channel['appurl'].'api/order/create';
		$data = array(
			"payId" => TRADE_NO,
			"param" => '', // vmqfox支持自定义参数
			"type" => $paytype,
			"price" => $order['realmoney'],
			"isHtml" => '1',
			"notifyUrl" => $conf['localurl'].'pay/notify/'.TRADE_NO.'/',
			"returnUrl" => $siteurl.'pay/return/'.TRADE_NO.'/',
		);
		
		// vmqfox的签名算法：md5('payId=' + payId + '&param=' + param + '&type=' + type + '&price=' + price + '&key=' + key)
		$signStr = 'payId='.$data['payId'].'&param='.$data['param'].'&type='.$data['type'].'&price='.$data['price'].'&key='.$channel['appkey'];
		$data["sign"] = md5($signStr);

        if (is_https() && substr($apiurl, 0, 7)=='http://') {
			$jump_url = $apiurl.'?'.http_build_query($data);
			return ['type'=>'jump','url'=>$jump_url];
        }else{
			$html_text = '<form action="'.$apiurl.'" method="post" id="dopay">';
			foreach($data as $k => $v) {
				$html_text .= "<input type=\"hidden\" name=\"{$k}\" value=\"{$v}\" />\n";
			}
			$html_text .= '<input type="submit" value="正在跳转"></form><script>document.getElementById("dopay").submit();</script>';

			return ['type'=>'html','data'=>$html_text];
		}
	}

	//异步回调
	static public function notify(){
		global $channel, $order;

		// vmqfox使用POST请求但参数在URL中，需要兼容GET和POST
		$payId = self::getParam('payId');//商户订单号
		$param = self::getParam('param', '');//自定义参数，可能为空
		$type = self::getParam('type');//支付方式 ：微信支付为1 支付宝支付为2 中国银联（云闪付）传入3 QQ钱包传入4
		$price = self::getParam('price');//订单金额
		$reallyPrice = self::getParam('reallyPrice');//实际支付金额
		$sign = self::getParam('sign');//校验签名，计算方式 = md5(payId + param + type + price + reallyPrice + 通讯密钥)

		if(!$payId || !$sign)return ['type'=>'html','data'=>'error_param'];

		// vmqfox的回调签名算法，注意param可能为空字符串
		$_sign = md5($payId . $param . $type . $price . $reallyPrice . $channel['appkey']);
		if ($_sign !== $sign)return ['type'=>'html','data'=>'error_sign'];

		$out_trade_no = daddslashes($payId);
		if($out_trade_no == TRADE_NO && round($price,2)==round($order['realmoney'],2)){
			processNotify($order, $out_trade_no);
		}
		return ['type'=>'html','data'=>'success'];
	}

	//同步回调
	static public function return(){
		global $channel, $order;

		// vmqfox使用POST请求但参数在URL中，需要兼容GET和POST
		$payId = self::getParam('payId');//商户订单号
		$param = self::getParam('param', '');//自定义参数，可能为空
		$type = self::getParam('type');//支付方式 ：微信支付为1 支付宝支付为2 中国银联（云闪付）传入3 QQ钱包传入4
		$price = self::getParam('price');//订单金额
		$reallyPrice = self::getParam('reallyPrice');//实际支付金额
		$sign = self::getParam('sign');//校验签名，计算方式 = md5(payId + param + type + price + reallyPrice + 通讯密钥)

		if(!$payId || !$sign)return ['type'=>'error','data'=>'参数不完整'];

		// vmqfox的回调签名算法，注意param可能为空字符串
		$_sign = md5($payId . $param . $type . $price . $reallyPrice . $channel['appkey']);
		if ($_sign !== $sign)return ['type'=>'error','data'=>'签名校验失败'];

		$out_trade_no = daddslashes($payId);
		if($out_trade_no == TRADE_NO && round($price,2)==round($order['realmoney'],2)){
			processReturn($order, $out_trade_no);
		}else{
			return ['type'=>'error','data'=>'订单信息校验失败'];
		}
	}

	// 辅助方法：兼容GET和POST参数获取
	private static function getParam($key, $default = '') {
		if (isset($_GET[$key]) && $_GET[$key] !== '') {
			return $_GET[$key];
		}
		if (isset($_POST[$key]) && $_POST[$key] !== '') {
			return $_POST[$key];
		}
		return $default;
	}

}